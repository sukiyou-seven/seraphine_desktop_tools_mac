package main

import (
	"bufio"
	"errors"
	"os"
	"os/user"
	"strconv"
	"strings"
	"sync"
	"time"
)

// errUnknownAccount 表示用户填写的所有者或用户组在服务器上不存在。
// 文件接口把它翻译成 422，客户端才能区分「账户不存在」与「路径不允许操作」。
var errUnknownAccount = errors.New("unknown account")

// accountSnapshot 是账户表的一份内存快照。
//
// 文件列表要给每个条目显示属主名称。逐个调用 os/user 会反复解析账户表，而列表一屏
// 就可能上百条；面板又常在创建账户（建库、装软件）之后立刻刷新列表，所以快照带一个
// 短 TTL：热路径不读盘，新建的账户也能很快出现（查不到时还会强制刷新一次）。
//
// 主表来自 /etc/passwd 与 /etc/group 的一次扫描（一次遍历换整份映射，比逐条查询快得
// 多），查不到的再退回 os/user —— 走 NSS 的实现能看见目录服务里的账户，也能让
// fork/exec 之外的本地账户正常显示。
type accountSnapshot struct {
	mu        sync.Mutex
	loadedAt  time.Time
	userName  map[int]string
	groupName map[int]string
	userId    map[string]int
	groupId   map[string]int
}

var accountCache struct {
	sync.Mutex
	snapshot *accountSnapshot
}

const accountCacheTTL = 15 * time.Second

// readAccounts 读取 passwd 格式的文件，同时返回「ID → 名称」与「名称 → ID」两张表。
// /etc/passwd 与 /etc/group 的第三列都是 ID，所以两者共用这一个解析器。
func readAccounts(path string) (map[int]string, map[string]int, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer file.Close()
	byID := make(map[int]string)
	byName := make(map[string]int)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, ":")
		if len(fields) < 3 || fields[0] == "" {
			continue
		}
		id, err := strconv.Atoi(fields[2])
		if err != nil {
			continue
		}
		byID[id] = fields[0]
		byName[fields[0]] = id
	}
	return byID, byName, scanner.Err()
}

func loadAccounts() (*accountSnapshot, error) {
	users, userIds, err := readAccounts("/etc/passwd")
	if err != nil {
		return nil, err
	}
	groups, groupIds, err := readAccounts("/etc/group")
	if err != nil {
		// 组表读不到不影响显示属主，但改属时就不能按组名解析了。
		groups, groupIds = map[int]string{}, map[string]int{}
	}
	return &accountSnapshot{loadedAt: time.Now(), userName: users, groupName: groups,
		userId: userIds, groupId: groupIds}, nil
}

// accounts 返回账户快照。force 为真时忽略缓存重新读取。读盘失败时退回上一次快照，
// 至少还能显示数字 ID，不会让整个目录列表失败。
func accounts(force bool) *accountSnapshot {
	accountCache.Lock()
	defer accountCache.Unlock()
	if !force && accountCache.snapshot != nil && time.Since(accountCache.snapshot.loadedAt) < accountCacheTTL {
		return accountCache.snapshot
	}
	snapshot, err := loadAccounts()
	if err != nil {
		return accountCache.snapshot
	}
	accountCache.snapshot = snapshot
	return snapshot
}

// names 把 uid/gid 换成显示名，查不到就用数字。
func (s *accountSnapshot) names(uid, gid int) (string, string) {
	if s == nil {
		return strconv.Itoa(uid), strconv.Itoa(gid)
	}
	name := strconv.Itoa(uid)
	if found, ok := s.userNameOf(uid); ok {
		name = found
	}
	group := strconv.Itoa(gid)
	if found, ok := s.groupNameOf(gid); ok {
		group = found
	}
	return name, group
}

func (s *accountSnapshot) userIDOf(name string) (int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if id, ok := s.userId[name]; ok {
		return id, true
	}
	account, err := user.Lookup(name)
	if err != nil {
		return 0, false
	}
	id, err := strconv.Atoi(account.Uid)
	if err != nil {
		return 0, false
	}
	s.userId[name] = id
	s.userName[id] = name
	return id, true
}

func (s *accountSnapshot) groupIDOf(name string) (int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if id, ok := s.groupId[name]; ok {
		return id, true
	}
	group, err := user.LookupGroup(name)
	if err != nil {
		return 0, false
	}
	id, err := strconv.Atoi(group.Gid)
	if err != nil {
		return 0, false
	}
	s.groupId[name] = id
	s.groupName[id] = name
	return id, true
}

func (s *accountSnapshot) userNameOf(uid int) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if name, ok := s.userName[uid]; ok {
		return name, true
	}
	account, err := user.LookupId(strconv.Itoa(uid))
	if err != nil {
		return "", false
	}
	s.userName[uid] = account.Username
	s.userId[account.Username] = uid
	return account.Username, true
}

func (s *accountSnapshot) groupNameOf(gid int) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if name, ok := s.groupName[gid]; ok {
		return name, true
	}
	group, err := user.LookupGroupId(strconv.Itoa(gid))
	if err != nil {
		return "", false
	}
	s.groupName[gid] = group.Name
	s.groupId[group.Name] = gid
	return group.Name, true
}

// lookupAccount 先把用户填的值当数字 ID 解析（chown 本来就接受数字），否则查账户表；
// 查不到时强制刷新一次快照，避免刚建好的账户被缓存挡住。
func lookupAccount(value string, find func(*accountSnapshot, string) (int, bool)) (int, bool) {
	if id, err := strconv.Atoi(value); err == nil && id >= 0 {
		return id, true
	}
	if snapshot := accounts(false); snapshot != nil {
		if id, ok := find(snapshot, value); ok {
			return id, true
		}
	}
	if snapshot := accounts(true); snapshot != nil {
		if id, ok := find(snapshot, value); ok {
			return id, true
		}
	}
	return 0, false
}

// resolveOwnership 解析客户端填写的所有者与用户组，空值表示保持原样（-1）。
func resolveOwnership(owner, group string) (int, int, error) {
	uid, gid := -1, -1
	if value := strings.TrimSpace(owner); value != "" {
		id, ok := lookupAccount(value, (*accountSnapshot).userIDOf)
		if !ok {
			return 0, 0, errUnknownAccount
		}
		uid = id
	}
	if value := strings.TrimSpace(group); value != "" {
		id, ok := lookupAccount(value, (*accountSnapshot).groupIDOf)
		if !ok {
			return 0, 0, errUnknownAccount
		}
		gid = id
	}
	if uid < 0 && gid < 0 {
		return 0, 0, errInvalidFilePath
	}
	return uid, gid, nil
}
