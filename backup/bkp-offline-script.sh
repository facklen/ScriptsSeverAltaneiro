#!/bin/bash
#
# vm_backup_offline.sh - Script para backup offline e limpeza de checkpoints
# Uso: sudo ./vm_backup_offline.sh /caminho/para/config.yaml vm_name
#
# Realiza backup offline completo da VM e limpa checkpoints

# Verificar argumentos
if [ $# -lt 2 ]; then
    echo "Uso: $0 <arquivo_config> <nome_vm>"
    exit 1
fi

CONFIG_FILE="$1"
VM_NAME="$2"

# Verificar se o script está rodando como root
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: Execute este script como root (sudo)"
    exit 1
fi

# Incluir funções comuns
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ -f "${SCRIPT_DIR}/vm-bkp-common.sh" ]; then
    source "${SCRIPT_DIR}/vm-bkp-common.sh"
else
    echo "ERRO: Arquivo de funções comuns não encontrado"
    exit 1
fi

# Verificar e carregar configuração
if ! load_config "$CONFIG_FILE"; then
    exit 1
fi

# Configurar ambiente para a VM
if ! setup_vm_env "$CONFIG_FILE" "$VM_NAME" "offline"; then
    exit 1
fi

# Função para limpeza em caso de falha
cleanup() {
    # Se a VM não estiver rodando e deveria estar, reinicie-a
    if [ "$VM_WAS_RUNNING" -eq 1 ] && ! is_vm_running "$VM_NAME"; then
        log "Executando limpeza - garantindo que a VM seja reiniciada"
        start_vm "$CONFIG_FILE" "$VM_NAME"
    fi
}

# Configurar trap para limpeza em caso de falha
trap cleanup EXIT INT TERM

# Iniciar script principal
log "====== INICIANDO BACKUP OFFLINE SEMANAL COM LIMPEZA DE CHECKPOINTS ======"
send_notification "$CONFIG_FILE" "info" "Iniciando processo de backup offline semanal para $VM_NAME"

# Verificar espaço em disco
if ! check_disk_space "$CONFIG_FILE" "$VM_NAME" "$BACKUP_DIR" "$VM_FILE"; then
    log "ERRO: Abortando backup por falta de espaço"
    exit 1
fi

# Verificar se VM está rodando e desligar se necessário
VM_WAS_RUNNING=0
if is_vm_running "$VM_NAME"; then
    VM_WAS_RUNNING=1
    log "VM está em execução. Iniciando procedimento de desligamento seguro."
    
    if ! safe_shutdown "$CONFIG_FILE" "$VM_NAME" "$SHUTDOWN_TIMEOUT"; then
        log "ERRO CRÍTICO: Falha no desligamento da VM. Abortando backup."
        send_notification "$CONFIG_FILE" "critical" "Backup offline abortado - falha no desligamento da VM"
        exit 1
    fi
else
    log "VM já está desligada. Prosseguindo com backup."
fi

# Inicializar variável de controle para backup bem-sucedido
BACKUP_SUCCESS=false

# Realizar o backup completo
log "Iniciando backup offline completo..."
if rsync -ah --progress --info=progress2 "$VM_FILE" "$BACKUP_FILE"; then
    log "Backup concluído com sucesso: $BACKUP_FILE"
    log "Tamanho do backup: $(du -h "$BACKUP_FILE" | cut -f1)"
    
    # Compactar o backup
    log "Compactando arquivo de backup..."
    if gzip -f "$BACKUP_FILE"; then
        log "Compactação concluída: ${BACKUP_FILE}.gz"
        
        # Verificar integridade do arquivo compactado
        if gzip -t "${BACKUP_FILE}.gz"; then
            log "Verificação de integridade concluída com sucesso"
            BACKUP_SUCCESS=true
        else
            log "AVISO: Verificação de integridade falhou!"
            send_notification "$CONFIG_FILE" "warning" "Verificação de integridade do backup falhou"
        fi
        
        # Manter apenas os últimos N backups semanais
        log "Removendo backups antigos (mantendo os últimos $RETENTION_COUNT)..."
        find "$BACKUP_DIR" -name "${VM_NAME}-full-*.gz" -type f | sort -r | tail -n +$((RETENTION_COUNT+1)) | xargs --no-run-if-empty rm -f
        
        # Calcular tamanho total dos backups
        TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
        log "Tamanho total dos backups armazenados: $TOTAL_SIZE"
        
        send_notification "$CONFIG_FILE" "info" "Backup offline concluído com sucesso. Tamanho: $(du -h "${BACKUP_FILE}.gz" | cut -f1)"
    else
        log "AVISO: Falha na compactação do arquivo de backup"
        send_notification "$CONFIG_FILE" "warning" "Falha na compactação do arquivo de backup"
    fi
else
    log "ERRO: Falha no backup offline da VM"
    send_notification "$CONFIG_FILE" "critical" "Falha no backup offline completo - erro na cópia do arquivo"
    
    # Se falhar, remover arquivo parcial se existir
    [ -f "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE"
    
    # Reiniciar VM se estava rodando
    if [ "$VM_WAS_RUNNING" -eq 1 ]; then
        start_vm "$CONFIG_FILE" "$VM_NAME"
    fi
    
    exit 1
fi

# Reiniciar a VM se estava rodando antes
if [ "$VM_WAS_RUNNING" -eq 1 ]; then
    log "VM estava em execução antes do backup. Reiniciando..."
    if ! start_vm "$CONFIG_FILE" "$VM_NAME"; then
        log "AVISO: Não foi possível reiniciar a VM automaticamente!"
        send_notification "$CONFIG_FILE" "warning" "VM não reiniciou automaticamente após backup"
    fi
else
    log "VM não estava em execução antes do backup. Mantendo desligada."
fi

# Limpar checkpoints se o backup foi bem-sucedido
if [ "$BACKUP_SUCCESS" = true ]; then
    # Aguardar um tempo para garantir que a VM esteja estável após o reinício
    log "Aguardando 60 segundos antes de iniciar a limpeza de checkpoints..."
    sleep 60
    
    # Executar limpeza de checkpoints
    cleanup_checkpoints "$CONFIG_FILE" "$VM_NAME" "$KEEP_LAST_CHECKPOINT" "$BACKUP_SUCCESS"
else
    log "Backup não foi totalmente bem-sucedido. Mantendo checkpoints por segurança."
    send_notification "$CONFIG_FILE" "warning" "Checkpoints mantidos por precaução - backup não totalmente validado"
fi

log "====== PROCESSO DE BACKUP OFFLINE SEMANAL E LIMPEZA CONCLUÍDO ======"
send_notification "$CONFIG_FILE" "info" "Processo completo de backup semanal e limpeza concluído"
exit 0
