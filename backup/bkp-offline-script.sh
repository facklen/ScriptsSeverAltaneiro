#!/bin/bash
#
# bkp-offline-script.sh - Script para backup offline e limpeza de checkpoints
# Uso: sudo ./bkp-offline-script.sh /caminho/para/config.yaml vm_name
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
        
        if [ -n "$CURRENT_DISK_PATH" ] && [ -n "$ORIGINAL_DISK_PATH" ]; then
            # Se tínhamos informações sobre os discos, usar para reiniciar corretamente
            log "Tentando iniciar a VM com configuração adequada..."
            
            # Se temos um caminho de disco atual e original, e eles são diferentes, tentar criar um novo snapshot
            if [ -f "$ORIGINAL_DISK_PATH" ]; then
                log "Tentando criar um novo snapshot para reiniciar a VM..."
                NEW_CHECKPOINT="${BACKUP_DIR}/${VM_NAME}-checkpoint-$(date +%Y%m%d_%H%M%S).qcow2"
                
                if qemu-img create -f qcow2 -b "$ORIGINAL_DISK_PATH" "$NEW_CHECKPOINT"; then
                    log "Criado novo snapshot: $NEW_CHECKPOINT"
                    
                    # Definir o novo disco para a VM
                    if virsh dumpxml "$VM_NAME" > /tmp/${VM_NAME}_config.xml; then
                        # Substituir caminho do disco no XML
                        sed -i "s|$CURRENT_DISK_PATH|$NEW_CHECKPOINT|g" /tmp/${VM_NAME}_config.xml
                        
                        # Redefinir a VM com a nova configuração
                        virsh define /tmp/${VM_NAME}_config.xml
                        rm -f /tmp/${VM_NAME}_config.xml
                        
                        # Iniciar a VM
                        start_vm "$CONFIG_FILE" "$VM_NAME"
                        return
                    fi
                fi
            fi
        fi
        
        # Se chegamos aqui, tentar método padrão
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

# Verificar configuração da VM antes de desligar
log "Verificando configuração atual da VM..."
CURRENT_DISK_PATH=$(virsh domblklist "$VM_NAME" | grep vda | awk '{print $2}')
ORIGINAL_DISK_PATH=""

# Verificar se é um checkpoint
if [ -n "$CURRENT_DISK_PATH" ] && [[ "$CURRENT_DISK_PATH" == *"checkpoint"* ]]; then
    log "VM está rodando a partir de um checkpoint: $CURRENT_DISK_PATH"
    
    # Tentar obter o arquivo base original
    if command -v qemu-img >/dev/null 2>&1; then
        BASE_INFO=$(qemu-img info --backing-chain "$CURRENT_DISK_PATH" 2>/dev/null | grep "backing file:" | head -1)
        if [ -n "$BASE_INFO" ]; then
            ORIGINAL_DISK_PATH=$(echo "$BASE_INFO" | sed -E 's/backing file: (.*)/\1/' | sed -E 's/ \(.*\)//')
            log "Arquivo base detectado: $ORIGINAL_DISK_PATH"
        fi
    fi
    
    # Se não conseguir detectar via qemu-img, tentar por convenção de nomenclatura
    if [ -z "$ORIGINAL_DISK_PATH" ] || [ ! -f "$ORIGINAL_DISK_PATH" ]; then
        ORIGINAL_DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
        if [ -f "$ORIGINAL_DISK_PATH" ]; then
            log "Arquivo base encontrado por convenção: $ORIGINAL_DISK_PATH"
        else
            log "AVISO: Não foi possível determinar o arquivo base original da VM"
            ORIGINAL_DISK_PATH=""
        fi
    fi
    
    log "VM ROD A VM será reiniciada com uma nova configuração após o backup"
else
    log "VM está usando um disco padrão: $CURRENT_DISK_PATH"
    ORIGINAL_DISK_PATH="$CURRENT_DISK_PATH"
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
    if [ $VM_WAS_RUNNING -eq 1 ]; then
        start_vm "$CONFIG_FILE" "$VM_NAME"
    fi
    
    exit 1
fi

# Reiniciar a VM se estava rodando antes
if [ $VM_WAS_RUNNING -eq 1 ]; then
    log "VM estava em execução antes do backup. Reiniciando..."
    
    # Se a VM estava rodando de um checkpoint, precisamos recriar o checkpoint
    if [ -n "$CURRENT_DISK_PATH" ] && [[ "$CURRENT_DISK_PATH" == *"checkpoint"* ]] && [ -n "$ORIGINAL_DISK_PATH" ] && [ -f "$ORIGINAL_DISK_PATH" ]; then
        log "Preparando para reiniciar VM que estava rodando de um checkpoint..."
        
        # Criar novo checkpoint baseado no arquivo original
        NEW_CHECKPOINT="${BACKUP_DIR}/${VM_NAME}-checkpoint-$(date +%Y%m%d_%H%M%S).qcow2"
        log "Criando novo checkpoint: $NEW_CHECKPOINT"
        
        if command -v qemu-img >/dev/null 2>&1; then
            if qemu-img create -f qcow2 -b "$ORIGINAL_DISK_PATH" "$NEW_CHECKPOINT"; then
                log "Novo checkpoint criado com sucesso"
                
                # Exportar configuração da VM
                log "Configurando VM para usar o novo checkpoint..."
                if virsh dumpxml "$VM_NAME" > /tmp/${VM_NAME}_config.xml; then
                    # Substituir caminho do disco no XML
                    sed -i "s|$CURRENT_DISK_PATH|$NEW_CHECKPOINT|g" /tmp/${VM_NAME}_config.xml
                    
                    # Redefinir a VM com a nova configuração
                    if virsh define /tmp/${VM_NAME}_config.xml; then
                        log "VM reconfigurada com sucesso para usar o novo checkpoint"
                        rm -f /tmp/${VM_NAME}_config.xml
                    else
                        log "ERRO: Falha ao redefinir a VM com a nova configuração"
                        rm -f /tmp/${VM_NAME}_config.xml
                    fi
                else
                    log "ERRO: Falha ao exportar configuração da VM"
                fi
            else
                log "ERRO: Falha ao criar novo checkpoint"
            fi
        else
            log "AVISO: qemu-img não disponível, não é possível criar novo checkpoint"
        fi
    fi
    
    # Tentar iniciar a VM
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
