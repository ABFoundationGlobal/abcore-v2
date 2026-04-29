pipeline {
    agent { label "${params.SERVER}" }

    // ─── 手动触发时的参数表单 ──────────────────────────────────────────
    parameters {
        choice(
            name: 'SERVER',
            choices: ['server-1', 'server-2', 'server-3', 'server-4'],
            description: '目标部署服务器'
        )
        choice(
            name: 'NODE_ID',
            choices: ['val-0', 'val-1', 'val-2', 'val-3', 'val-4', 'rpc-0'],
            description: 'val-0~val-4=验证者节点  rpc-0=RPC节点'
        )
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
    }

    // ─── 环境变量 ──────────────────────────────────────────────────────
    environment {
        IMAGE_NAME     = "abfoundationglobal/abcore-v2:${params.TAG}"
        TARBALL        = "abcore-v2-${params.TAG}-linux-amd64.tar.gz"
        GITHUB_RELEASE = "https://github.com/ABFoundationGlobal/abcore-v2/releases/download/${params.TAG}"
        DATADIR        = "/data/abcore-v2/${params.NETWORK}/${params.NODE_ID}"
        CONTAINER_NAME = "abcore-${params.NETWORK}-${params.NODE_ID}"
    }

    stages {

        // ── Stage 1：解析端口 + 推断节点角色 ──────────────────────────
        stage('参数确认') {
            steps {
                script {
                    // ── SERVER / NODE_ID 合法性校验 ──────────────────
                    def validMapping = [
                        'server-1': ['val-0', 'val-1'],
                        'server-2': ['val-2', 'val-3'],
                        'server-3': ['val-4'],
                        'server-4': ['rpc-0']
                    ]
                    if (!validMapping[params.SERVER].contains(params.NODE_ID)) {
                        error "❌ ${params.NODE_ID} 不属于 ${params.SERVER}，正确映射：${validMapping[params.SERVER]}，请检查参数"
                    }

                    // ── 端口映射表 ──────────────────────────────────
                    // 同一台服务器上两个节点用不同端口段错开：
                    //   val-0 / val-2 / val-4 / rpc-0 → 19545 / 19546 / 31300
                    //   val-1 / val-3               → 19547 / 19548 / 31301
                    def rpcPortMap = [
                        'val-0': '19545',
                        'val-1': '19547',
                        'val-2': '19545',
                        'val-3': '19547',
                        'val-4': '19545',
                        'rpc-0': '19545'
                    ]
                    def wsPortMap = [
                        'val-0': '19546',
                        'val-1': '19548',
                        'val-2': '19546',
                        'val-3': '19548',
                        'val-4': '19546',
                        'rpc-0': '19546'
                    ]
                    def p2pPortMap = [
                        'val-0': '31300',
                        'val-1': '31301',
                        'val-2': '31300',
                        'val-3': '31301',
                        'val-4': '31300',
                        'rpc-0': '31300'
                    ]

                    // 根据 NODE_ID 推断节点角色
                    def nodeRole = params.NODE_ID.startsWith('val') ? 'validator' : 'rpc'

                    env.RPC_PORT  = rpcPortMap[params.NODE_ID]
                    env.WS_PORT   = wsPortMap[params.NODE_ID]
                    env.P2P_PORT  = p2pPortMap[params.NODE_ID]
                    env.NODE_ROLE = nodeRole

                    sh """
                        echo "========================================="
                        echo " 服务器    : ${params.SERVER}"
                        echo " 节点ID    : ${params.NODE_ID}"
                        echo " 节点角色  : ${env.NODE_ROLE}"
                        echo " 目标版本  : ${params.TAG}"
                        echo " 网络      : ${params.NETWORK}"
                        echo " 容器名    : ${CONTAINER_NAME}"
                        echo " 数据目录  : ${DATADIR}"
                        echo " 镜像      : ${IMAGE_NAME}"
                        echo " RPC端口   : ${env.RPC_PORT}"
                        echo " WS端口    : ${env.WS_PORT}"
                        echo " P2P端口   : ${env.P2P_PORT}"
                        echo "========================================="
                    """
                }
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
                    sudo mkdir -p ${DATADIR}/keystore

                    if [ "${env.NODE_ROLE}" = "validator" ]; then
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
                    // validator 需要 full sync + archive，rpc-snap 不需要
                    def extraArgs = (env.NODE_ROLE == 'validator') ? '--syncmode full --gcmode archive' : ''

                    sh """
                        set -e

                        docker run -d \\
                          --name ${CONTAINER_NAME} \\
                          --restart unless-stopped \\
                          -v ${DATADIR}:/data \\
                          -p 0.0.0.0:${env.RPC_PORT}:8545 \\
                          -p 0.0.0.0:${env.WS_PORT}:8546 \\
                          -p 0.0.0.0:${env.P2P_PORT}:33333 \\
                          -p 0.0.0.0:${env.P2P_PORT}:33333/udp \\
                          -e NETWORK=${params.NETWORK} \\
                          ${IMAGE_NAME} \\
                          --port 33333 \\
                          --http --http.addr 0.0.0.0 --http.port 8545 \\
                                 --http.vhosts localhost \\
                                 --http.api 'txpool,net,web3,eth' \\
                          --ws   --ws.addr 0.0.0.0   --ws.port 8546 \\
                                 --ws.api 'txpool,net,web3,eth' \\
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

                    echo "--- RPC 健康检查 ---"
                    curl -s -X POST http://127.0.0.1:${env.RPC_PORT} \\
                        -H 'Content-Type: application/json' \\
                        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' || true
                """
            }
        }
    }

    post {
        success {
            sh """
                echo "========================================="
                echo " ✅ 部署成功"
                echo " 服务器: ${params.SERVER}"
                echo " 节点  : ${params.NODE_ID}"
                echo " 网络  : ${params.NETWORK}"
                echo " 版本  : ${params.TAG}"
                echo " RPC   : http://0.0.0.0:${env.RPC_PORT}"
                echo " WS    : ws://0.0.0.0:${env.WS_PORT}"
                echo " P2P   : ${env.P2P_PORT}"
                echo "========================================="
            """
        }
        failure {
            sh """
                echo "========================================="
                echo " ❌ 部署失败，请查看上方日志"
                echo " 服务器: ${params.SERVER}"
                echo " 节点  : ${params.NODE_ID}"
                echo " 网络  : ${params.NETWORK}"
                echo " 版本  : ${params.TAG}"
                echo "========================================="
            """
        }
    }
}