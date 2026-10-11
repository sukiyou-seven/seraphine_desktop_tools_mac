sera_begin kafka 4.2.1 /etc/systemd/system/sera-kafka.service
file=kafka_2.13-4.2.1.tgz
sera_stage '下载 Apache Kafka 官方发布包'
sera_download512 "$file" "https://downloads.apache.org/kafka/4.2.1/$file" f643e31266268e920aa98ead9a061026c98dac2886932ad468565ba59bcb7fb4f98a4c4f62727367e1bd87515f3b016e6f6ccccad8b12bdef8b091b0fb577170
kafka_archive=$sera_archive
sera_create_user seraphim-kafka
sera_create_prefix
tar -xzf "$kafka_archive" -C "$sera_prefix" --strip-components=1
if [ -f "$sera_root/server/openjdk/.sera-installed" ]; then
    ln -s "$sera_root/server/openjdk" "$sera_prefix/jdk"
else
    case "$(uname -m)" in
        x86_64) arch=x64; sha=dbb698396d478e7fa2b1e50f4103324b2a99b90569ee27c33f2261f9215cf41e ;;
        aarch64|arm64) arch=aarch64; sha=69df11a02cfa3ef7d7ca645e03edce6778ec090e100f6ae2b42097865730ac52 ;;
        *) echo 'Kafka 所需 JDK 不支持当前架构' >&2; exit 1 ;;
    esac
    jdk_file=OpenJDK25U-jdk_${arch}_linux_hotspot_25.0.4.1_1.tar.gz
    sera_stage '下载 Kafka 所需 Eclipse Temurin JDK'
    sera_download "$jdk_file" "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/$jdk_file" "$sha"
    install -d -m 0755 "$sera_prefix/jdk"
    tar -xzf "$sera_archive" -C "$sera_prefix/jdk" --strip-components=1
fi
install -d -m 0750 -o seraphim-kafka -g seraphim-kafka "$sera_prefix/data"
install -d -m 0750 -o seraphim-kafka -g seraphim-kafka "$sera_root/logs/kafka"
cat > "$sera_prefix/config/sera-server.properties" <<'EOF'
process.roles=broker,controller
node.id=1
controller.quorum.bootstrap.servers=127.0.0.1:19093
controller.listener.names=CONTROLLER
listeners=PLAINTEXT://127.0.0.1:19092,CONTROLLER://127.0.0.1:19093
advertised.listeners=PLAINTEXT://127.0.0.1:19092
inter.broker.listener.name=PLAINTEXT
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
log.dirs=/www/seraphim/server/kafka/data
num.partitions=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
EOF
sera_stage '初始化 Kafka KRaft 存储'
cluster_id=$(JAVA_HOME="$sera_prefix/jdk" KAFKA_HEAP_OPTS='-Xms128m -Xmx256m' "$sera_prefix/bin/kafka-storage.sh" random-uuid)
JAVA_HOME="$sera_prefix/jdk" KAFKA_HEAP_OPTS='-Xms128m -Xmx256m' "$sera_prefix/bin/kafka-storage.sh" format --standalone -t "$cluster_id" -c "$sera_prefix/config/sera-server.properties"
chown -R seraphim-kafka:seraphim-kafka "$sera_prefix/data"
cat > "$sera_unit" <<'EOF'
[Unit]
Description=Seraphim Apache Kafka
After=network-online.target
[Service]
User=seraphim-kafka
Group=seraphim-kafka
Environment=JAVA_HOME=/www/seraphim/server/kafka/jdk
Environment=LOG_DIR=/www/seraphim/logs/kafka
Environment="KAFKA_HEAP_OPTS=-Xms256m -Xmx512m"
ExecStart=/www/seraphim/server/kafka/bin/kafka-server-start.sh /www/seraphim/server/kafka/config/sera-server.properties
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/www/seraphim/server/kafka/data /www/seraphim/logs/kafka
StandardOutput=append:/www/seraphim/logs/kafka.log
StandardError=append:/www/seraphim/logs/kafka.log
[Install]
WantedBy=multi-user.target
EOF
sera_commit
