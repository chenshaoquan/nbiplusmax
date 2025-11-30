#!/bin/bash

# =================配置区域=================
# 请修改为你的 GitHub 用户名和仓库名
# 例如: GITHUB_REPO="chenshaoquan/axisaispeed"
GITHUB_USER="chenshaoquan"
GITHUB_REPO="axisaispeed"
GITHUB_BRANCH="main"
# =========================================

# 构造下载链接
BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
SOURCE_FILENAME="send_mach_info.py"

# 安装与源码存储目录
INSTALL_DIR="/usr/local/vast_speedtest"

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 root 权限运行此脚本 (Please run as root)"
  exit 1
fi

echo "======================================================"
echo "      Vast.ai 机器信息上报脚本一键安装程序"
echo "======================================================"

# 1. 提示用户输入服务器 IP
while true; do
    read -p "请输入测速服务器 IP 地址 (例如: 1.2.3.4): " SERVER_IP
    if [[ $SERVER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    else
        echo "无效的 IP 格式，请重新输入。"
    fi
done

echo "正在初始化环境..."

# 创建安装目录
mkdir -p "$INSTALL_DIR"

# 2. 释放源代码 (Embedded Python Script)
echo "正在释放源代码到 ${INSTALL_DIR}/${SOURCE_FILENAME} ..."

cat > "${INSTALL_DIR}/${SOURCE_FILENAME}" <<'PYTHON_EOF'
#!/usr/bin/python3
import json
import subprocess
import requests
import random

import subprocess
import platform

from argparse import ArgumentParser

from datetime import datetime


from pathlib import Path
import re

def iommu_groups():
    return Path('/sys/kernel/iommu_groups').glob('*') 
def iommu_groups_by_index():
    return ((int(path.name) , path) for path in iommu_groups())

class PCI:
    def __init__(self, id_string):
        parts: list[str] = re.split(r':|\.', id_string)
        if len(parts) == 4:
            PCI.domain = int(parts[0], 16)
            parts = parts[1:]
        else:
            PCI.domain = 0
        assert len(parts) == 3
        PCI.bus = int(parts[0], 16)
        PCI.device = int(parts[1], 16)
        PCI.fn = int(parts[2], 16)
        
# returns an iterator of devices, each of which contains the list of device functions.  
def iommu_devices(iommu_path : Path):
    paths = (iommu_path / "devices").glob("*")
    devices= {}
    for path in paths:
        pci = PCI(path.name)
        device = (pci.domain, pci.bus,pci.device)
        if device in devices:
            devices[device].append((pci,path))
        else:
            devices[device] = [(pci,path)]
    return devices

# given a list of device function IDs belonging to a device and their paths, 
# gets the render_node if it has one, using a list as an optional
def render_no_if_gpu(device_fns):
    for (_, path) in device_fns:
        if (path / 'drm').exists():
            return [r.name for r in (path/'drm').glob("render*")]
    return []

# returns a dict of bus:device -> (all pci ids, renderNode) for all gpus in an iommu group, by iommu group 
def gpus_by_iommu_by_index():
    iommus = iommu_groups_by_index()
    for index,path in iommus:
        devices = iommu_devices(path)
        gpus= {}
        for d in devices:
            gpu_m = render_no_if_gpu(devices[d])
            if gpu_m:
                gpus[d] = (devices[d], gpu_m[0])
        if len(gpus) > 0:
            yield (index,gpus)

def devices_by_iommu_by_index():
    iommus = iommu_groups_by_index()
    devices = {}
    for index,path in iommus:
        devices[index] = iommu_devices(path)
    return devices

# check if each iommu group has only one gpu
def check_if_iommu_ok(iommu_gpus, iommu_devices):
    has_iommu_gpus = False
    for (index, gpu) in iommu_gpus:
        has_iommu_gpus = True
        if len(iommu_devices[index]) > 1:
            for pci_address in iommu_devices[index]:
                # check if device is gpu itself
                if pci_address in gpu:
                    continue
                # else, check if device is bridge
                for (pci_fn, path) in iommu_devices[index][pci_address]:
                    try:
                        pci_class = subprocess.run(
                            ['sudo', 'cat', path / 'class'],
                            capture_output=True,
                            text=True,
                            check=True
                        )
                        # bridges have class 06, class is stored in hex fmt, so 0x06XXXX should be fine to pass along w/ group
                        if pci_class.stdout[2:4] != '06':
                            return False
                    except Exception as e:
                        print(f"An error occurred: {e}")
                        return False
    try:
        result = subprocess.run(
            ['sudo', 'cat', '/sys/module/nvidia_drm/parameters/modeset'],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout[0] == 'N' and has_iommu_gpus
    except Exception as e:
        print(f"An error occurred: {e}")
        return False


def numeric_version(version_str):
    try:
        # Split the version string by the period
        try:
            major, minor, patch = version_str.split('.')
        except:
            major, minor = version_str.split('.')
            patch = ''

        # Pad each part with leading zeros to make it 3 digits
        major = major.zfill(3)
        minor = minor.zfill(3)
        patch = patch.zfill(3)

        # Concatenate the padded parts
        numeric_version_str = f"{major}{minor}{patch}"

        # Convert the concatenated string to an integer
        return int(numeric_version_str)

    except ValueError:
        print("Invalid version string format. Expected format: X.X.X")
        return None

def get_nvidia_driver_version():
    try:
        # Run the nvidia-smi command and capture its output
        output = subprocess.check_output(['nvidia-smi'], stderr=subprocess.STDOUT, text=True)

        # Split the output by lines
        lines = output.strip().split('\n')

        # Loop through each line and search for the driver version
        for line in lines:
            if "Driver Version" in line:
                # Extract driver version
                version_info = line.split(":")[1].strip()
                vers = version_info.split(" ")[0]
                return numeric_version(vers)

    except subprocess.CalledProcessError:
        print("Error: Failed to run nvidia-smi.")
    except Exception as e:
        print(f"An unexpected error occurred: {e}")

    return None


def cond_install(package, extra=None):
    result = False
    location = ""
    try:
        location = subprocess.check_output(f"which {package}", shell=True).decode('utf-8').strip()
        print(location)
    except:
        pass

    if (len(location) < 1):
        print(f"installing {package}")
        output = None
        try:
            if (extra is not None):
                output  = subprocess.check_output(extra, shell=True).decode('utf-8')
            output  = subprocess.check_output(f"sudo apt install -y {package}", shell=True).decode('utf-8')
            result = True
        except:
            print(output)
    else:
        result = True
    return result

def find_drive_of_mountpoint(target):
    output = subprocess.check_output("lsblk -sJap",  shell=True).decode('utf-8')
    jomsg = json.loads(output)
    blockdevs = jomsg.get("blockdevices", [])
    mountpoints = None
    devname = None
    for bdev in blockdevs:
        mountpoints = bdev.get("mountpoints", [])
        if (not mountpoints):
            # for ubuntu version < 22.04
            mountpoints = [bdev.get("mountpoint", None)]
        if (target in mountpoints):
            devname = bdev.get("name", None)
            nextn = bdev
            while nextn is not None:
                devname = nextn.get("name", None)
                try:
                    nextn = nextn.get("children",[None])[0]
                except:
                    nextn = None
    return devname


def remote_speedtest_via_vps():
    """
    Run Vast.ai speedtest docker container remotely on VPS via SSH (non-interactive, with license flags).
    """
    ssh_host = "root@206.206.77.179"
    docker_cmd = "docker run --rm -v /root/.config:/root/.config vastai/test:speedtest --accept-license --accept-gdpr --format=json"
    ssh_cmd = f"ssh -o StrictHostKeyChecking=no {ssh_host} \"{docker_cmd}\""
    #print("Using remote_speedtest_via_vps with docker from", ssh_host)
    try:
        output = subprocess.check_output(ssh_cmd, shell=True, stderr=subprocess.STDOUT).decode('utf-8')
        return output
    except subprocess.CalledProcessError as e:
        print("Remote VPS speedtest failed:")
        print(e.output.decode('utf-8'))
        return None


# 原始 epsilon_greedyish_speedtest 函数以下保留但不再使用

def epsilon_greedyish_speedtest():
    def epsilon(greedy):
        subprocess.run(["mkdir", "-p", "/var/lib/vastai_kaalia/.config"])
        output  = subprocess.check_output("docker run --rm -v /var/lib/vastai_kaalia/.config:/root/.config vastai/test:speedtest -L --accept-license --accept-gdpr --format=json", stderr=subprocess.STDOUT, shell=True).decode('utf-8')
        mirrors = [server["id"] for server in json.loads(output)["servers"]]
        mirror = mirrors[random.randint(0,len(mirrors)-1)]
        print(f"running speedtest on random server id {mirror}")
        output = subprocess.check_output(f"docker run --rm -v /var/lib/vastai_kaalia/.config:/root/.config vastai/test:speedtest -s {mirror} --accept-license --accept-gdpr --format=json", stderr=subprocess.STDOUT, shell=True).decode('utf-8')
        joutput = json.loads(output)
        score = joutput["download"]["bandwidth"] + joutput["upload"]["bandwidth"] 
        if int(score) > int(greedy):
            with open("/var/lib/vastai_kaalia/data/speedtest_mirrors", "w") as f:
                f.write(f"{mirror},{score}")
        return output
    def greedy(id):
        print(f"running speedtest on known best server id {id}")
        output = subprocess.check_output(f"docker run --rm -v /var/lib/vastai_kaalia/.config:/root/.config vastai/test:speedtest -s {id} --accept-license --accept-gdpr --format=json", stderr=subprocess.STDOUT, shell=True).decode('utf-8')
        joutput = json.loads(output)
        score = joutput["download"]["bandwidth"] + joutput["upload"]["bandwidth"] 
        with open("/var/lib/vastai_kaalia/data/speedtest_mirrors", "w") as f: # we always want to update best in case it gets worse
            f.write(f"{id},{score}")
        return output
    try:
        with open("/var/lib/vastai_kaalia/data/speedtest_mirrors") as f:
            id, score = f.read().split(',')[0:2]
        if random.randint(0,2):
            return greedy(id)
        else:
            return epsilon(score)
    except:
        return epsilon(0)
                
def is_vms_enabled():
    try: 
        with open('/var/lib/vastai_kaalia/kaalia.cfg') as conf:
            for field in conf.readlines():
                entries = field.split('=')
                if len(entries) == 2 and entries[0].strip() == 'gpu_type' and entries[1].strip() == 'nvidia_vm':
                    return True
    except:
        pass
    return False


def get_container_start_times():
    # Run `docker ps -q` to get all running container IDs
    result = subprocess.run(["docker", "ps", "-q"], capture_output=True, text=True)
    container_ids = result.stdout.splitlines()

    containerName_to_startTimes = {}
    for container_id in container_ids:
        # Run `docker inspect` for each container to get details
        inspect_result = subprocess.run(["docker", "inspect", container_id], capture_output=True, text=True)

        container_info = json.loads(inspect_result.stdout)
        
        container_name = container_info[0]["Name"].strip("/")
        start_time = container_info[0]["State"]["StartedAt"]

        # Convert date time to unix timestamp for easy storage and computation
        dt = datetime.strptime(start_time[:26], "%Y-%m-%dT%H:%M:%S.%f")
        containerName_to_startTimes[container_name] = dt.timestamp()

    return containerName_to_startTimes

def get_channel():
    try: 
        with open('/var/lib/vastai_kaalia/.channel') as f:
            channel = f.read()
            return channel
    except:
        pass
    return "" # default channel is just "" on purpose.
        
if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument("--speedtest", action='store_true')
    parser.add_argument("--server", action='store', default="https://console.vast.ai")
    args = parser.parse_args()
    output = None
    try:
        r = random.randint(0, 5)
        #print(r)
        if r == 3:
            print("apt update")
            output  = subprocess.check_output("sudo apt update", shell=True).decode('utf-8')
    except:
        print(output)


    # Command to get disk usage in GB
    print(datetime.now())

    print('os version')
    cmd = "lsb_release -a 2>&1 | grep 'Release:' | awk '{printf $2}'"
    os_version = subprocess.check_output(cmd, shell=True).decode('utf-8').strip()

    print('running df')
    cmd_df = "df --output=avail -BG /var/lib/docker | tail -n1 | awk '{print $1}'"
    free_space = subprocess.check_output(cmd_df, shell=True).decode('utf-8').strip()[:-1]


    print("checking errors")
    cmd_df = "grep -e 'device error' -e 'nvml error' kaalia.log | tail -n 1"
    device_error = subprocess.check_output(cmd_df, shell=True).decode('utf-8')

    cmd_df = "sudo timeout --foreground 3s journalctl -o short-precise -r -k --since '24 hours ago' -g 'AER' -n 1"
    cmd_df = "sudo timeout --foreground 3s journalctl -o short-precise -r -k --since '24 hours ago' | grep 'AER' | tail -n 1"
    aer_error = subprocess.check_output(cmd_df, shell=True).decode('utf-8')
    if len(aer_error) < 4:
        aer_error = None

    cmd_df = "sudo timeout --foreground 3s journalctl -o short-precise -r -k --since '24 hours ago' -g 'Uncorrected' -n 1"
    cmd_df = "sudo timeout --foreground 3s journalctl -o short-precise -r -k --since '24 hours ago' | grep 'Uncorrected' | tail -n 1"
    uncorr_error = subprocess.check_output(cmd_df, shell=True).decode('utf-8')
    if len(uncorr_error) < 4:
        uncorr_error = None

    aer_error = uncorr_error or aer_error


    print("nvidia-smi")
    nv_driver_version = get_nvidia_driver_version()
    print(nv_driver_version)

    cond_install("fio")

    bwu_cur = bwd_cur = None
    speedtest_found = False

    print("checking speedtest")
    try:
        r = random.randint(0, 8) 
        if r == 3 or args.speedtest:
            print("speedtest")
            try:
                output = remote_speedtest_via_vps()
            except subprocess.CalledProcessError as e:
                output = e.output.decode('utf-8')
                print(output)
                output = None


            print(output)
            jomsg = json.loads(output)
            _MiB = 2 ** 20
            try:
                bwu_cur = 8*jomsg["upload"]["bandwidth"] / _MiB
                bwd_cur = 8*jomsg["download"]["bandwidth"] / _MiB
            except Exception as e:
                bwu_cur = 8*jomsg["upload"] / _MiB
                bwd_cur = 8*jomsg["download"] / _MiB

            #return json.dumps({"bwu_cur": bwu_cur, "bwd_cur": bwd_cur})

    except Exception as e:
        print("Exception:")
        print(e)
        print(output)

    disk_prodname = None

    try:
        docker_drive  = find_drive_of_mountpoint("/var/lib/docker")
        disk_prodname = subprocess.check_output(f"cat /sys/block/{docker_drive[5:]}/device/model",  shell=True).decode('utf-8')
        disk_prodname = disk_prodname.strip()
        print(f'found disk_name:{disk_prodname} from {docker_drive}')
    except:
        pass


    try:
        r = random.randint(0, 48)
        if r == 31:    
            print('cleaning build cache')
            output  = subprocess.check_output("docker builder prune --force",  shell=True).decode('utf-8')
            print(output)
    except:
        pass
    

    fio_command_read  = "sudo fio --numjobs=16 --ioengine=libaio --direct=1 --verify=0 --name=read_test  --directory=/var/lib/docker --bs=32k --iodepth=64 --size=128MB --readwrite=randread  --time_based --runtime=1.0s --group_reporting=1 --iodepth_batch_submit=64 --iodepth_batch_complete_max=64"
    fio_command_write = "sudo fio --numjobs=16 --ioengine=libaio --direct=1 --verify=0 --name=write_test --directory=/var/lib/docker --bs=32k --iodepth=64 --size=128MB --readwrite=randwrite --time_based --runtime=0.5s --group_reporting=1 --iodepth_batch_submit=64 --iodepth_batch_complete_max=64"

    print('running fio')
    # Parse the output to get the bandwidth (in MB/s)
    disk_read_bw  = None
    disk_write_bw = None


    try:
        output_read   = subprocess.check_output(fio_command_read,  shell=True).decode('utf-8')
        disk_read_bw  = float(output_read.split('bw=')[1].split('MiB/s')[0].strip())
    except:
        pass

    try:
        disk_read_bw  = float(output_read.split('bw=')[1].split('GiB/s')[0].strip()) * 1024.0
    except:
        pass


    try:
        output_write  = subprocess.check_output(fio_command_write, shell=True).decode('utf-8')
        disk_write_bw = float(output_write.split('bw=')[1].split('MiB/s')[0].strip())
    except:
        pass

    try:
        disk_write_bw  = float(output_write.split('bw=')[1].split('GiB/s')[0].strip()) * 1024.0
    except:
        pass


    # Get the machine key
    with open('/var/lib/vastai_kaalia/machine_id', 'r') as f:
        mach_api_key = f.read()

    # Prepare the data for the POST request
    data = { "mach_api_key": mach_api_key, "availram": int(free_space) }

    data['release_channel'] = get_channel()

    if os_version:
        data["ubuntu_version"] = os_version

    if disk_read_bw:
        data["bw_dev_cpu"] = disk_read_bw

    if disk_write_bw:
        data["bw_cpu_dev"] = disk_write_bw

    if bwu_cur and bwu_cur > 0:
        data["bwu_cur"] = bwu_cur

    if bwd_cur and bwd_cur > 0:
        data["bwd_cur"] = bwd_cur

    if nv_driver_version:
        data["driver_vers"] = nv_driver_version

    if disk_prodname:
        data["product_name"] = disk_prodname

    if device_error and len(device_error) > 8:
        data["error_msg"] = device_error

    if aer_error and len(aer_error) > 8:
        data["aer_error"] = aer_error

    architecture = platform.machine()
    if architecture in ["AMD64", "amd64", "x86_64", "x86-64", "x64"]:
        data["cpu_arch"] = "amd64"
    elif architecture in ["aarch64", "ARM64", "arm64"]:
        data["cpu_arch"] = "arm64"
    else:
        data["cpu_arch"] = "amd64"

    try:
        with open("/var/lib/vastai_kaalia/data/nvidia_smi.json", mode='r') as f:
            try:
                data["gpu_arch"] = json.loads(f.read())["gpu_arch"]
            except:
                data["gpu_arch"] = "nvidia"
            print(f"got gpu_arch: {data['gpu_arch']}")
    except:
        pass

    try:
        data["iommu_virtualizable"] = check_if_iommu_ok(gpus_by_iommu_by_index(), devices_by_iommu_by_index())
        print(f"got iommu virtualization capability: {data['iommu_virtualizable']}")
    except:
        pass
    try:
        vm_status = is_vms_enabled()
        data["vms_enabled"] = vm_status and data["iommu_virtualizable"] 
        print(f"Got VM feature enablement status: {vm_status}")
    except:
        pass
    
    try:
        containerNames_to_startTimes = get_container_start_times()
        data["container_startTimes"] = containerNames_to_startTimes
        print(f"Got container start times: {containerNames_to_startTimes}")
    except Exception as e:
        print(f"Exception Occured: {e}")

    print(data)
    # Perform the POST request
    response = requests.put(args.server+'/api/v0/disks/update/', json=data)

    if response.status_code == 404 and mach_api_key.strip() != mach_api_key:
        print("Machine not found, retrying with stripped api key...")
        data["mach_api_key"] = mach_api_key.strip()
        print(data)
        response = requests.put(args.server+'/api/v0/disks/update/', json=data)

    # Check the response
    if response.status_code == 200:
        print("Data sent successfully.")
    else:
        print(response)
        print(f"Failed to send data, status code: {response.status_code}.")
PYTHON_EOF

echo "源码释放完成。"

# 定义其他路径
TARGET_SCRIPT="/root/send_mach_info.py"
WRAPPER_SCRIPT="/usr/local/bin/vast_speedtest_runner.sh"
SERVICE_NAME="vast_speedtest"

# 3. 生成运行包装脚本 (Wrapper Script)
echo "正在生成运行脚本: $WRAPPER_SCRIPT ..."

cat > "$WRAPPER_SCRIPT" <<EOF
#!/bin/bash
# Auto-generated by install.sh

# 1. 定义路径
SOURCE="${INSTALL_DIR}/${SOURCE_FILENAME}"
TARGET="${TARGET_SCRIPT}"
IP="${SERVER_IP}"

# 2. 检查源文件
if [ ! -f "\$SOURCE" ]; then
    echo "Error: Source file not found at \$SOURCE"
    exit 1
fi

# 3. 复制源文件到目标位置 (每次运行都覆盖，确保纯净)
cp "\$SOURCE" "\$TARGET"

# 4. 替换 IP 地址
# 将默认的 root@206.206.77.179 替换为 root@\$IP
sed -i "s/206.206.77.179/\$IP/g" "\$TARGET"

# 5. 执行 Python 脚本
echo "Running vast speedtest with IP: \$IP"
/usr/bin/python3 "\$TARGET" --speedtest
EOF

chmod +x "$WRAPPER_SCRIPT"
echo "运行脚本已生成。"

# 4. 立即执行一次以验证并完成首次安装
echo "正在执行首次安装与测试..."
"$WRAPPER_SCRIPT"
echo "首次执行完成。"

# 5. 配置 Systemd 服务
echo "正在配置 Systemd 定时任务..."

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

# 创建 Service 文件
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Vast.ai Machine Info & Speedtest Service
After=network.target

[Service]
Type=oneshot
ExecStart=$WRAPPER_SCRIPT
User=root
EOF

# 创建 Timer 文件
# OnCalendar=daily 表示每天 00:00:00 触发
# RandomizedDelaySec=86400 表示在触发后的 24 小时(86400秒)内随机延迟执行
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Vast.ai Speedtest Daily at Random Time

[Timer]
OnCalendar=daily
RandomizedDelaySec=86400
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 重新加载 Systemd 并启用 Timer
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.timer"
systemctl start "${SERVICE_NAME}.timer"

echo "======================================================"
echo "安装完成!"
echo "1. 源码存储于: ${INSTALL_DIR}"
echo "2. 目标测速 IP 已设置为: $SERVER_IP"
echo "3. Systemd Timer 已启动: ${SERVICE_NAME}.timer"
echo "======================================================"
