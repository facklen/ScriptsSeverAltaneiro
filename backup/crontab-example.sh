# Configuração de crontab para automação de backups de VMs
# Para instalar: sudo crontab -e

# Backup por checkpoint diário (às 01:00 da manhã)
0 1 * * * /opt/scripts/vm_backup_manager.sh /opt/scripts/vm_backup_config.yaml checkpoint > /dev/null 2>&1

# Backup offline semanal (domingo às 03:00 da manhã)
0 3 * * 0 /opt/scripts/vm_backup_manager.sh /opt/scripts/vm_backup_config.yaml offline > /dev/null 2>&1

# Backup específico de uma VM específica
# 30 2 * * * /opt/scripts/vm_backup_manager.sh /opt/scripts/vm_backup_config.yaml checkpoint winserver2022 > /dev/null 2>&1
