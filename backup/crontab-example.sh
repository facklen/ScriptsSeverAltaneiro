# Configuração de crontab para automação de backups de VMs
# Para instalar: sudo crontab -e

# Backup offline semanal (domingo às 03:00 da manhã)
0 3 * * 0 /home/goku/scripts/backup/vm_backup.sh /home/goku/scripts/backup/vm_backup_config.yaml > /dev/null 2>&1

# Backup específico de uma VM específica
# 30 2 * * 6 /opt/scripts/vm_backup.sh /opt/scripts/vm_backup_config.yaml winserver2022 > /dev/null 2>&1
