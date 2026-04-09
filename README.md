# CloudDrive2 多实例一键部署与管理脚本

一键部署和管理多个 CloudDrive2 实例，支持添加、删除、状态查看、更新、重启、反代配置生成和卸载清理。

## 一键安装运行

```bash
bash <(curl -sL https://raw.githubusercontent.com/AiLi1337/clouddrive2_manager/main/clouddrive2_manager.sh)
```

## 功能菜单

```
  1) 添加新的 CD2 实例
  2) 删除已有的 CD2 实例
  3) 查看当前所有实例运行状态
  4) 一键更新所有实例
  5) 重启指定或全部实例
  6) 生成反向代理配置 (Caddy/Nginx)
  7) 卸载全部实例并清理数据
  0) 退出脚本
```

## 环境要求

- 操作系统：Linux（推荐 Ubuntu 20.04+ / Debian 11+ / CentOS 8+）
- 权限：必须以 root 用户运行
- Docker 与 Docker Compose：脚本会自动检测并安装
- FUSE 内核模块：脚本会自动检测并尝试加载

## 使用说明

### 添加实例

1. 输入实例名称（仅限英文、数字、下划线，如 `cd2_115`）
2. 输入宿主机映射端口（默认从 19798 自动递增推荐可用端口）
3. 脚本自动创建目录、生成配置并启动容器

### 删除实例

1. 选择要删除的实例编号
2. 确认是否同时删除本地持久化数据

### 查看状态

以表格形式显示所有实例的名称、容器ID、运行状态、端口和内存占用

### 一键更新

自动拉取最新镜像、重启所有容器、清理旧镜像

### 生成反向代理配置

输入主域名后，自动为每个运行中的实例分配子域名，支持生成 Caddy 或 Nginx 配置文件

## 目录结构

```
/opt/clouddrive2_manager/
├── docker-compose.yml
├── <实例名>/
│   ├── Config/        # CD2 配置文件
│   └── CloudNAS/      # CD2 挂载点数据
```

## Docker Compose 配置说明

每个实例自动包含以下关键配置：

- `privileged: true` — 特权模式
- `pid: "host"` — 主机 PID 命名空间
- `/dev/fuse:/dev/fuse` — FUSE 设备映射
- `Config` 和 `CloudNAS:shared` 卷映射

## License

MIT
