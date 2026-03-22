import psutil
import platform
import json
import socket
import subprocess
import requests
import argparse
from datetime import datetime
from typing import Dict, List, Any


def get_cpu_info() -> Dict:
    return {
        "model": platform.processor() or "Unknown",
        "physical_cores": psutil.cpu_count(logical=False),
        "logical_cores": psutil.cpu_count(logical=True),
        "usage_percent": psutil.cpu_percent(interval=1.0),
        "frequency_mhz": psutil.cpu_freq().current if psutil.cpu_freq() else 0,
        "present": True
    }


def get_memory_info() -> Dict:
    mem = psutil.virtual_memory()
    return {
        "total_gb": round(mem.total / (1024**3), 2),
        "used_gb": round(mem.used / (1024**3), 2),
        "available_gb": round(mem.available / (1024**3), 2),
        "percent_used": mem.percent,
        "present": mem.total > 0
    }


def get_disk_info() -> List[Dict]:
    disks = []
    for part in psutil.disk_partitions(all=False):
        if part.fstype:
            try:
                usage = psutil.disk_usage(part.mountpoint)
                # Basic SMART health check (requires smartmontools + root)
                smart_status = "Unknown"
                try:
                    smart = subprocess.run(
                        ["smartctl", "-H", part.device], capture_output=True, text=True, timeout=5
                    )
                    smart_status = "PASSED" if "PASSED" in smart.stdout else "FAILED"
                except:
                    pass

                disks.append({
                    "device": part.device,
                    "mountpoint": part.mountpoint,
                    "size_gb": round(usage.total / (1024**3), 2),
                    "free_gb": round(usage.free / (1024**3), 2),
                    "percent_used": usage.percent,
                    "smart_status": smart_status,
                    "present": True
                })
            except:
                pass
    return disks


def get_network_info() -> Dict:
    nets = {}
    addrs = psutil.net_if_addrs()
    stats = psutil.net_if_stats()
    for iface in stats:
        nets[iface] = {
            "is_up": stats[iface].isup,
            "speed_mbps": stats[iface].speed,
            "ip": [a.address for a in addrs.get(iface, []) if a.family == socket.AF_INET],
            "present": stats[iface].isup
        }
    return nets


def detect_gpu() -> Dict:
    gpu = {"present": False, "vendor": "None", "model": "None", "details": ""}

    # NVIDIA
    try:
        res = subprocess.run(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=5)
        if res.returncode == 0:
            gpu = {"present": True, "vendor": "NVIDIA", "model": res.stdout.strip(), "details": "NVIDIA GPU detected"}
            return gpu
    except:
        pass

    # Linux lspci (AMD/Intel/others)
    try:
        res = subprocess.run(["lspci", "-nn"], capture_output=True, text=True, timeout=5)
        for line in res.stdout.splitlines():
            if any(x in line.upper() for x in ["VGA", "3D", "DISPLAY"]):
                gpu = {"present": True, "vendor": "Integrated/AMD/Intel", "model": line.strip(), "details": "Detected via lspci"}
                return gpu
    except:
        pass

    # Windows fallback
    if platform.system() == "Windows":
        try:
            res = subprocess.run(["wmic", "path", "win32_VideoController", "get", "name"], capture_output=True, text=True)
            name = res.stdout.strip().split("\n")[-1].strip()
            if name and name != "Name":
                gpu = {"present": True, "vendor": "Windows GPU", "model": name, "details": "Detected via WMIC"}
        except:
            pass

    return gpu


def get_temperatures() -> Dict:
    temps = {}
    try:
        if hasattr(psutil, "sensors_temperatures"):
            temps = psutil.sensors_temperatures()
    except:
        pass
    return temps


def determine_usability(report: Dict) -> Dict:
    reasons = []
    status = "Fully Usable"

    # Critical thresholds for lab PCs
    if report["cpu"]["usage_percent"] > 85:
        status = "Degraded"
        reasons.append("CPU overloaded (>85%)")
    if report["memory"]["percent_used"] > 90:
        status = "Degraded"
        reasons.append("RAM critically full (>90%)")
    if report["memory"]["total_gb"] < 4:
        status = "Degraded"
        reasons.append("Low RAM (<4 GB)")

    for disk in report["disks"]:
        if disk["percent_used"] > 92:
            status = "Degraded"
            reasons.append(f"Disk {disk['mountpoint']} almost full")
        if disk["smart_status"] == "FAILED":
            status = "Not Usable"
            reasons.append(f"Disk {disk['device']} SMART FAILED - Hardware fault")

    # Network check
    if not any(n["is_up"] for n in report["network"].values()):
        status = "Not Usable"
        reasons.append("No active network interface")

    # GPU missing (if lab PCs are expected to have one)
    if not report["gpu"]["present"]:
        reasons.append("GPU missing (may be acceptable for basic labs)")

    if not report["disks"]:
        status = "Not Usable"
        reasons.append("No storage detected")

    return {
        "status": status,
        "reasons": reasons,
        "overall_health_score": max(0, 100 - len(reasons) * 15)
    }


def build_full_report() -> Dict[str, Any]:
    report = {
        "timestamp": datetime.now().isoformat(),
        "hostname": socket.gethostname(),
        "ip_address": socket.gethostbyname(socket.gethostname()),
        "os": platform.platform(),
        "uptime_seconds": int(psutil.boot_time() - datetime.now().timestamp()) * -1,  # negative for uptime
        "cpu": get_cpu_info(),
        "memory": get_memory_info(),
        "disks": get_disk_info(),
        "network": get_network_info(),
        "gpu": detect_gpu(),
        "temperatures": get_temperatures(),
        "hardware_missing": {
            "cpu": not get_cpu_info()["present"],
            "ram": not get_memory_info()["present"],
            "storage": len(get_disk_info()) == 0,
            "network": not any(n["is_up"] for n in get_network_info().values()),
            "gpu": not detect_gpu()["present"]
        }
    }

    usability = determine_usability(report)
    report["usability"] = usability["status"]
    report["usability_reasons"] = usability["reasons"]
    report["health_score"] = usability["overall_health_score"]

    return report


def send_to_central_server(report: Dict, server_url: str):
    """Send report to your central monitoring server"""
    try:
        r = requests.post(server_url, json=report, timeout=10)
        if r.status_code == 200:
            print(f"✅ Report successfully sent to root admin dashboard: {server_url}")
        else:
            print(f"⚠️ Server returned {r.status_code}")
    except Exception as e:
        print(f"❌ Could not reach central server: {e}")


def main():
    parser = argparse.ArgumentParser(description="PC Lab Watch - Hardware Monitor")
    parser.add_argument("--send", metavar="URL", help="Send report to central server URL")
    args = parser.parse_args()

    report = build_full_report()

    # Print clean report for immediate use
    print(json.dumps(report, indent=4, ensure_ascii=False))

    # Save local copy (useful for debugging)
    filename = f"pc_status_{report['hostname']}_{datetime.now().strftime('%Y%m%d_%H%M')}.json"
    with open(filename, "w") as f:
        json.dump(report, f, indent=4)
    print(f"\n📁 Local report saved: {filename}")

    # Send to central server if requested
    if args.send:
        send_to_central_server(report, args.send)

    # Final summary for quick glance
    print("\n" + "="*60)
    print(f"PC: {report['hostname']} | Status: {report['usability']}")
    print(f"Health Score: {report['health_score']}/100")
    if report["usability_reasons"]:
        print("Issues:", ", ".join(report["usability_reasons"]))
    print("="*60)


if __name__ == "__main__":
    main()
