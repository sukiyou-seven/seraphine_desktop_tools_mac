package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

// Release details come from the publisher at request time. Only the selected
// release's publisher URL and digest are handed to the installer.
type runtimeRelease struct {
	Version string `json:"version"`
	URL     string `json:"-"`
	SHA256  string `json:"-"`
	SHA512  string `json:"-"`
	File    string `json:"-"`
}

type goDownloadRelease struct {
	Version string `json:"version"`
	Stable  bool   `json:"stable"`
	Files   []struct {
		Filename string `json:"filename"`
		SHA256   string `json:"sha256"`
	} `json:"files"`
}

type releaseCacheEntry struct {
	releases []runtimeRelease
	expires  time.Time
}

var releaseCache = struct {
	sync.Mutex
	entries map[string]releaseCacheEntry
}{entries: map[string]releaseCacheEntry{}}
var releaseHTTP = &http.Client{Timeout: 20 * time.Second}
var versionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+|_[0-9]+-b[0-9]+)?$`)
var digestPattern = regexp.MustCompile(`^[a-fA-F0-9]{64}(?:[a-fA-F0-9]{64})?$`)

func releaseJSON(ctx context.Context, address string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Seraphim/1.0")
	resp, err := releaseHTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("发布源返回 HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 12<<20)).Decode(out)
}

func releaseText(ctx context.Context, address string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "Seraphim/1.0")
	resp, err := releaseHTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("发布源返回 HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return string(data), err
}

func releaseArch() (string, string, error) {
	switch runtime.GOARCH {
	case "amd64":
		return "x64", "amd64", nil
	case "arm64":
		return "arm64", "arm64", nil
	}
	return "", "", errors.New("当前架构不受支持")
}

func validatedRelease(r runtimeRelease) bool {
	if !versionPattern.MatchString(r.Version) || !digestPattern.MatchString(r.SHA256+r.SHA512) {
		return false
	}
	u, e := url.Parse(r.URL)
	if e != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return false
	}
	if r.File == "" || path.Base(r.File) != r.File || strings.ContainsAny(r.File, " \t\n") {
		return false
	}
	return true
}

func runtimeReleases(ctx context.Context, id string) ([]runtimeRelease, error) {
	key := id + "/" + runtime.GOARCH
	releaseCache.Lock()
	cached, ok := releaseCache.entries[key]
	releaseCache.Unlock()
	if ok && time.Now().Before(cached.expires) {
		return cached.releases, nil
	}
	releases, err := fetchRuntimeReleases(ctx, id)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	valid := make([]runtimeRelease, 0, len(releases))
	for _, r := range releases {
		if validatedRelease(r) && !seen[r.Version] {
			seen[r.Version] = true
			valid = append(valid, r)
		}
	}
	sort.SliceStable(valid, func(i, j int) bool { return compareVersion(valid[i].Version, valid[j].Version) > 0 })
	if len(valid) > 80 {
		valid = valid[:80]
	}
	if len(valid) == 0 {
		return nil, errors.New("发布源没有可用于当前架构的版本")
	}
	releaseCache.Lock()
	releaseCache.entries[key] = releaseCacheEntry{valid, time.Now().Add(15 * time.Minute)}
	releaseCache.Unlock()
	return valid, nil
}

func compareVersion(a, b string) int {
	var x, y [4]int
	fmt.Sscanf(a, "%d.%d.%d.%d", &x[0], &x[1], &x[2], &x[3])
	fmt.Sscanf(b, "%d.%d.%d.%d", &y[0], &y[1], &y[2], &y[3])
	for i := range x {
		if x[i] > y[i] {
			return 1
		}
		if x[i] < y[i] {
			return -1
		}
	}
	return 0
}

func fetchRuntimeReleases(ctx context.Context, id string) ([]runtimeRelease, error) {
	xarch, garch, err := releaseArch()
	if err != nil {
		return nil, err
	}
	switch id {
	case "go":
		lookupCtx, cancel := context.WithCancel(ctx)
		type goResult struct {
			data []goDownloadRelease
			err  error
		}
		results := make(chan goResult, 2)
		for _, address := range []string{"https://go.dev/dl/?mode=json&include=all", "https://golang.google.cn/dl/?mode=json&include=all"} {
			go func(address string) {
				var data []goDownloadRelease
				e := releaseJSON(lookupCtx, address, &data)
				results <- goResult{data, e}
			}(address)
		}
		var data []goDownloadRelease
		for range 2 {
			result := <-results
			if result.err == nil {
				data = result.data
				err = nil
				break
			}
			err = result.err
		}
		cancel()
		if len(data) == 0 {
			return nil, err
		}
		var out []runtimeRelease
		for _, v := range data {
			if !v.Stable {
				continue
			}
			version := strings.TrimPrefix(v.Version, "go")
			for _, f := range v.Files {
				if f.Filename == "go"+version+".linux-"+garch+".tar.gz" {
					out = append(out, runtimeRelease{version, "https://golang.google.cn/dl/" + f.Filename, f.SHA256, "", f.Filename})
				}
			}
		}
		return out, nil
	case "node":
		var data []struct {
			Version string `json:"version"`
			LTS     any    `json:"lts"`
		}
		err = releaseJSON(ctx, "https://nodejs.org/dist/index.json", &data)
		if err != nil {
			return nil, err
		}
		var out []runtimeRelease
		perMajor := map[string]int{}
		for _, v := range data {
			version := strings.TrimPrefix(v.Version, "v")
			if !versionPattern.MatchString(version) {
				continue
			}
			major := strings.Split(version, ".")[0]
			if perMajor[major] >= 3 || (perMajor[major] == 0 && len(perMajor) >= 5) {
				continue
			}
			file := "node-v" + version + "-linux-" + xarch + ".tar.xz"
			manifest, e := releaseText(ctx, "https://nodejs.org/dist/v"+version+"/SHASUMS256.txt")
			if e != nil {
				continue
			}
			for _, line := range strings.Split(manifest, "\n") {
				parts := strings.Fields(line)
				if len(parts) == 2 && parts[1] == file {
					out = append(out, runtimeRelease{version, "https://nodejs.org/dist/v" + version + "/" + file, parts[0], "", file})
					perMajor[major]++
					break
				}
			}
			if len(out) >= 15 {
				break
			}
		}
		return out, nil
	case "python":
		var data []struct {
			Name      string `json:"name"`
			Pre       bool   `json:"pre_release"`
			Published bool   `json:"is_published"`
			URI       string `json:"resource_uri"`
		}
		err = releaseJSON(ctx, "https://www.python.org/api/v2/downloads/release/?is_published=true", &data)
		if err != nil {
			return nil, err
		}
		sort.Slice(data, func(i, j int) bool {
			return compareVersion(strings.TrimPrefix(data[i].Name, "Python "), strings.TrimPrefix(data[j].Name, "Python ")) > 0
		})
		var out []runtimeRelease
		for _, v := range data {
			version := strings.TrimPrefix(v.Name, "Python ")
			if !v.Published || v.Pre || !versionPattern.MatchString(version) || strings.HasPrefix(version, "2.") {
				continue
			}
			var files []struct {
				URL string `json:"url"`
				SHA string `json:"sha256_sum"`
			}
			if releaseJSON(ctx, "https://www.python.org/api/v2/downloads/release_file/?release="+path.Base(v.URI), &files) != nil {
				continue
			}
			for _, f := range files {
				file := "Python-" + version + ".tar.xz"
				if strings.HasSuffix(f.URL, "/"+file) {
					out = append(out, runtimeRelease{version, f.URL, f.SHA, "", file})
					break
				}
			}
			if len(out) >= 30 {
				break
			}
		}
		return out, nil
	case "php":
		var index map[string]struct {
			Supported []string `json:"supported_versions"`
		}
		err = releaseJSON(ctx, "https://www.php.net/releases/index.php?json", &index)
		if err != nil {
			return nil, err
		}
		var out []runtimeRelease
		for _, branch := range index["8"].Supported {
			var v struct {
				Version string `json:"version"`
				Source  []struct {
					Filename string `json:"filename"`
					SHA      string `json:"sha256"`
				} `json:"source"`
			}
			if releaseJSON(ctx, "https://www.php.net/releases/index.php?json&version="+branch, &v) != nil {
				continue
			}
			for _, f := range v.Source {
				if f.Filename == "php-"+v.Version+".tar.xz" {
					out = append(out, runtimeRelease{v.Version, "https://www.php.net/distributions/" + f.Filename, f.SHA, "", f.Filename})
				}
			}
		}
		return out, nil
	case "openjdk":
		arch := xarch
		if arch == "arm64" {
			arch = "aarch64"
		}
		var available struct {
			Releases []int `json:"available_releases"`
		}
		if err := releaseJSON(ctx, "https://api.adoptium.net/v3/info/available_releases", &available); err != nil {
			return nil, err
		}
		var out []runtimeRelease
		for _, featureNumber := range available.Releases {
			feature := fmt.Sprint(featureNumber)
			var data []struct {
				Version struct {
					OpenJDKVersion string `json:"openjdk_version"`
				} `json:"version_data"`
				Binaries []struct {
					Package struct {
						Link     string `json:"link"`
						Name     string `json:"name"`
						Checksum string `json:"checksum"`
					} `json:"package"`
				} `json:"binaries"`
			}
			address := "https://api.adoptium.net/v3/assets/feature_releases/" + feature + "/ga?architecture=" + arch + "&image_type=jdk&os=linux&page_size=5"
			if err := releaseJSON(ctx, address, &data); err != nil {
				continue
			}
			for _, v := range data {
				version := strings.Split(v.Version.OpenJDKVersion, "+")[0]
				for _, b := range v.Binaries {
					out = append(out, runtimeRelease{version, b.Package.Link, b.Package.Checksum, "", b.Package.Name})
				}
			}
		}
		return out, nil
	case "dotnet":
		var index struct {
			Channels []struct {
				Phase string `json:"support-phase"`
				URL   string `json:"releases.json"`
			} `json:"releases-index"`
		}
		err = releaseJSON(ctx, "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json", &index)
		if err != nil {
			return nil, err
		}
		var out []runtimeRelease
		for _, channel := range index.Channels {
			if channel.Phase == "eol" {
				continue
			}
			var data struct {
				Releases []struct {
					SDKs []struct {
						Version string `json:"version"`
						Files   []struct {
							RID  string `json:"rid"`
							Name string `json:"name"`
							Hash string `json:"hash"`
							URL  string `json:"url"`
						} `json:"files"`
					} `json:"sdks"`
					SDK struct {
						Version string `json:"version"`
						Files   []struct {
							RID  string `json:"rid"`
							Name string `json:"name"`
							Hash string `json:"hash"`
							URL  string `json:"url"`
						} `json:"files"`
					} `json:"sdk"`
				} `json:"releases"`
			}
			if releaseJSON(ctx, channel.URL, &data) != nil {
				continue
			}
			for _, release := range data.Releases {
				sdkList := release.SDKs
				if release.SDK.Version != "" {
					sdkList = append(sdkList, release.SDK)
				}
				for _, sdk := range sdkList {
					for _, f := range sdk.Files {
						if f.RID == "linux-"+xarch && strings.HasSuffix(f.Name, ".tar.gz") {
							out = append(out, runtimeRelease{sdk.Version, f.URL, "", f.Hash, f.Name})
						}
					}
				}
				if len(out) >= 40 {
					break
				}
			}
		}
		return out, nil
	case "bun", "deno":
		repo := "oven-sh/bun"
		if id == "deno" {
			repo = "denoland/deno"
		}
		var data []struct {
			Tag        string `json:"tag_name"`
			Prerelease bool   `json:"prerelease"`
			Assets     []struct {
				Name   string `json:"name"`
				URL    string `json:"browser_download_url"`
				Digest string `json:"digest"`
			} `json:"assets"`
		}
		err = releaseJSON(ctx, "https://api.github.com/repos/"+repo+"/releases?per_page=40", &data)
		if err != nil {
			return nil, err
		}
		var out []runtimeRelease
		for _, v := range data {
			if v.Prerelease {
				continue
			}
			version := strings.TrimPrefix(strings.TrimPrefix(v.Tag, "bun-v"), "v")
			var file string
			if id == "bun" {
				arch := xarch
				if arch == "arm64" {
					arch = "aarch64"
				}
				file = "bun-linux-" + arch + ".zip"
			} else {
				arch := "x86_64"
				if xarch == "arm64" {
					arch = "aarch64"
				}
				file = "deno-" + arch + "-unknown-linux-gnu.zip"
			}
			for _, a := range v.Assets {
				if a.Name == file && strings.HasPrefix(a.Digest, "sha256:") {
					out = append(out, runtimeRelease{version, a.URL, strings.TrimPrefix(a.Digest, "sha256:"), "", id + "-" + version + "-" + file})
				}
			}
		}
		return out, nil
	case "ruby":
		html, err := releaseText(ctx, "https://www.ruby-lang.org/en/downloads/releases/")
		if err != nil {
			return nil, err
		}
		re := regexp.MustCompile(`(?s)<td><a href="(https://cache\.ruby-lang\.org/pub/ruby/[0-9.]+/ruby-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz)">download</a></td>\s*<td><a href="([^"]+)">`)
		hashRE := regexp.MustCompile(`SHA256:\s*([a-fA-F0-9]{64})`)
		matches := re.FindAllStringSubmatch(html, -1)
		var out []runtimeRelease
		seen := map[string]bool{}
		for _, m := range matches {
			if seen[m[2]] {
				continue
			}
			seen[m[2]] = true
			news, e := releaseText(ctx, "https://www.ruby-lang.org"+m[3])
			if e != nil {
				continue
			}
			position := strings.Index(news, m[1])
			if position < 0 {
				continue
			}
			hash := hashRE.FindStringSubmatch(news[position:])
			if len(hash) > 1 {
				out = append(out, runtimeRelease{m[2], m[1], hash[1], "", path.Base(m[1])})
			}
			if len(out) >= 15 {
				break
			}
		}
		return out, nil
	}
	return nil, errors.New("未知运行环境")
}
