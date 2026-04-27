pipeline {
    agent any

    // ─── 手动触发时的参数表单 ──────────────────────────────────────────
    parameters {
        string(
            name: 'TAG',
            defaultValue: 'v0.1.2',
            description: '目标镜像版本号，例如 v0.1.3'
        )
        choice(
            name: 'NETWORK',
            choices: ['testnet', 'mainnet'],
            description: '部署网络'
        )
        choice(
            name: 'NODE_ROLE',
            choices: ['rpc-snap', 'rpc-archive', 'validator'],
            description: 'rpc-snap=同步节点  rpc-archive=归档节点  validator=验证者节点'
        )
    }

    // ─── 环境变量 ──────────────────────────────────────────────────────
    environment {
        IMAGE_NAME     = "abfoundationglobal/abcore-v2:${params.TAG}"
        TARBALL        = "abcore-v2-${params.TAG}-linux-amd64.tar.gz"
        GITHUB_RELEASE = "https://github.com/ABFoundationGlobal/abcore-v2/releases/download/${params.TAG}"
        DATADIR        = "/data/abcore-v2/${params.NETWORK}"
        CONTAINER_NAME = "${params.NODE_ROLE == 'validator' ? 'abcore-' + params.NETWORK + '-validator-jenkins' : 'abcore-' + params.NETWORK + '-jenkins'}"
    }

    stages {

        // ── Stage 1：打印本次部署参数 ──────────────────────────────────
        stage('参数确认') {
            steps {
                sh """
                    echo "========================================="
                    echo " 网络      : ${params.NETWORK}"
                    echo " 节点角色  : ${params.NODE_ROLE}"
                    echo " 目标版本  : ${params.TAG}"
                    echo " 容器名    : ${CONTAINER_NAME}"
                    echo " 数据目录  : ${DATADIR}"
                    echo " 镜像      : ${IMAGE_NAME}"
                    echo "========================================="
                """
            }
        }

        // ── Stage 2：下载并加载新镜像 ──────────────────────────────────
        stage('下载镜像') {
            steps {
                sh """
                    set -e

                    # 本地已有该版本镜像则跳过下载
                    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '${IMAGE_NAME}'; then
                        echo "本地已存在镜像 ${IMAGE_NAME}，跳过下载"
                    else
                        echo "开始下载镜像压缩包..."
                        curl -L -o /tmp/${TARBALL} ${GITHUB_RELEASE}/${TARBALL}

                        echo "加载镜像到 Docker..."
                        docker load < /tmp/${TARBALL}

                        rm -f /tmp/${TARBALL}
                        echo "镜像加载完成"
                    fi

                    echo "--- 当前 abcore-v2 镜像列表 ---"
                    docker images | grep abcore-v2 || true
                """
            }
        }

        // ── Stage 3：准备数据目录 ──────────────────────────────────────
        stage('准备目录') {
            steps {
                sh """
                    mkdir -p ${DATADIR}/keystore

                    if [ "${params.NODE_ROLE}" = "validator" ]; then
                        if [ -z "\$(ls -A ${DATADIR}/keystore 2>/dev/null)" ]; then
                            echo "❌ validator 模式需要 keystore 文件，请先放入 ${DATADIR}/keystore/"
                            exit 1
                        fi
                        if [ ! -f "${DATADIR}/password.txt" ]; then
                            echo "❌ validator 模式需要 ${DATADIR}/password.txt"
                            exit 1
                        fi
                        echo "✅ keystore 和 password.txt 检查通过"
                    fi

                    echo "数据目录已就绪: ${DATADIR}"
                """
            }
        }

        // ── Stage 4：停止并移除旧容器 ──────────────────────────────────
        stage('停止旧容器') {
            steps {
                sh """
                    if docker ps -a --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}\$'; then
                        echo "发现旧容器 ${CONTAINER_NAME}，正在停止..."
                        docker stop ${CONTAINER_NAME}
                        docker rm   ${CONTAINER_NAME}
                        echo "旧容器已清理"
                    else
                        echo "未发现旧容器，跳过"
                    fi
                """
            }
        }

        // ── Stage 5：启动新容器 ────────────────────────────────────────
        stage('启动节点') {
            steps {
                script {
                    def extraArgs = ''
                    if (params.NODE_ROLE == 'rpc-archive' || params.NODE_ROLE == 'validator') {
                        extraArgs = '--syncmode full --gcmode archive'
                    }

                    sh """
                        set -e

                        docker run -d \\
                          --name ${CONTAINER_NAME} \\
                          --restart unless-stopped \\
                          -v ${DATADIR}:/data \\
                          -p 127.0.0.1:28545:8545 \\
                          -p 127.0.0.1:28546:8546 \\
                          -p 127.0.0.1:26060:6060 \\
                          -p 0.0.0.0:33335:33333 \\
                          -p 0.0.0.0:33335:33333/udp \\
                          -e NETWORK=${params.NETWORK} \\
                          ${IMAGE_NAME} \\
                          --port 33333 \\
                          --http --http.addr 0.0.0.0 --http.port 8545 \\
                                 --http.vhosts localhost \\
                                 --http.api 'txpool,net,web3,eth' \\
                          --ws   --ws.addr 0.0.0.0   --ws.port 8546 \\
                                 --ws.api 'txpool,net,web3,eth' \\
                          --pprof --pprof.addr 0.0.0.0 --pprof.port 6060 \\
                          ${extraArgs}

                        echo "容器已启动"
                    """
                }
            }
        }

        // ── Stage 6：验证节点状态 ──────────────────────────────────────
        stage('验证部署') {
            steps {
                sh """
                    echo "等待节点启动 10 秒..."
                    sleep 10

                    echo "--- 容器状态 ---"
                    docker ps | grep abcore || true

                    echo "--- 最新日志（30行）---"
                    docker logs --tail=30 ${CONTAINER_NAME} 2>&1 || true
                """
            }
        }
    }

    post {
        success {
            sh """
                echo "========================================="
                echo " ✅ 部署成功"
                echo " 网络  : ${params.NETWORK}"
                echo " 角色  : ${params.NODE_ROLE}"
                echo " 版本  : ${params.TAG}"
                echo "========================================="
            """
        }
        failure {
            sh """
                echo "========================================="
                echo " ❌ 部署失败，请查看上方日志"
                echo " 网络  : ${params.NETWORK}"
                echo " 角色  : ${params.NODE_ROLE}"
                echo " 版本  : ${params.TAG}"
                echo "========================================="
            """
        }
    }
}