#!/bin/bash
#
# bkp-checkpoint-script.sh - Script para backup com checkpoint
# Uso: sudo ./bkp-checkpoint-script.sh /caminho/para/config.yaml vm_name
#
# Realiza backup incremental usando checkpoints sem desligar a VM

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
if ! setup_vm_env "$CONFIG_FILE" "$VM_NAME" "checkpoint"; then
    exit 1
fi

# Verificar que BACKUP_FILE está correto e tem caminhos absolutos
if [[ "$BACKUP_FILE" != /* ]]; then
    log "ERRO: BACKUP_FILE não é um caminho absoluto: $BACKUP_FILE"
    exit 1
fi

log "Arquivo de backup será: $BACKUP_FILE"

# Iniciar script principal
log "====== INICIANDO BACKUP COM CHECKPOINT PARA $VM_NAME ======"

# Verificar espaço em disco
if ! check_disk_space "$CONFIG_FILE" "$VM_NAME" "$BACKUP_DIR" "$VM_FILE"; then
    log "AVISO: Continuando mesmo com pouco espaço em disco"
fi

# Verificar diretório para armazenar a RAM
if [ "$KEEP_RAM" = "true" ] && [ ! -d "/var/lib/libvirt/qemu/ram" ]; then
    mkdir -p "/var/lib/libvirt/qemu/ram"
    log "Diretório para snapshots de RAM criado: /var/lib/libvirt/qemu/ram"
fi

# Obter o nome do disco da VM
DISK_NAME=$(get_disk_name "$VM_NAME")
if [ -z "$DISK_NAME" ]; then
    log "ERRO: Não foi possível determinar o nome do disco para a VM $VM_NAME"
    send_notification "$CONFIG_FILE" "error" "Não foi possível determinar o nome do disco para a VM"
    exit 1
fi
log "Nome do disco detectado: $DISK_NAME"

# Para debug: imprimir informação detalhada sobre os discos da VM
log "Saída do comando 'virsh domblklist':"
virsh domblklist "$VM_NAME" >> "$LOG_FILE" 2>&1

# Verificar que o nome do disco foi detectado corretamente
log "Verificando se o disco '$DISK_NAME' é válido para a VM $VM_NAME..."
if ! virsh dumpxml "$VM_NAME" | grep -q "<target dev='$DISK_NAME'"; then
    log "AVISO: O nome do disco '$DISK_NAME' não aparece no XML da VM."
    send_notification "$CONFIG_FILE" "warning" "Possível problema com detecção do nome do disco"
    # Não sair, vamos tentar mesmo assim
fi

# Limpar snapshots órfãos antes de iniciar
clean_orphaned_snapshots "$VM_NAME"

# Criar checkpoint e fazer o backup
CHECKPOINT_NAME=$(create_checkpoint "$VM_NAME" "$KEEP_RAM")
if [ $? -eq 0 ]; then
    log "Checkpoint $CHECKPOINT_NAME criado, iniciando backup..."
    send_notification "$CONFIG_FILE" "info" "Iniciando backup incremental com checkpoint $CHECKPOINT_NAME"
    
    # Verificar que o diretório de backup existe
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        log "Criado diretório de backup: $BACKUP_DIR"
    fi
    
    # Garantir que temos o nome do disco correto
    if [ -z "$DISK_NAME" ]; then
        log "ERRO: Nome de disco não encontrado. Abortando."
        send_notification "$CONFIG_FILE" "error" "Nome de disco não encontrado"
        exit 1
    fi
    
    # Obter o caminho real do disco usando a nova função get_disk_path
    DISK_PATH=$(get_disk_path "$VM_NAME" "$DISK_NAME")
    if [ $? -ne 0 ] || [ -z "$DISK_PATH" ]; then
        log "ERRO: Falha ao obter caminho do disco. Abortando."
        send_notification "$CONFIG_FILE" "error" "Falha ao obter caminho do disco"
        exit 1
    fi
    
    log "Caminho do disco original detectado: $DISK_PATH"
    
    # Inicializar variável de sucesso do backup
    BACKUP_SUCCESS=false
    
    # Criar snapshot externo ou copiar direto, dependendo do tipo de disco
    if [ -f "$DISK_PATH" ] && [[ "$DISK_PATH" != *"checkpoint"* ]]; then
        # Se for um arquivo regular, tentar criar snapshot externo
        log "Criando snapshot externo com nome de disco: $DISK_NAME"
        virsh snapshot-create-as --domain "$VM_NAME" \
            --name "temp_export" \
            --diskspec "$DISK_NAME,snapshot=external,file=$BACKUP_FILE" \
            --atomic \
            --disk-only
            
        if [ $? -eq 0 ]; then
            # Snapshot externo criado com sucesso
            log "Snapshot externo criado com sucesso"
            virsh snapshot-delete --domain "$VM_NAME" --snapshotname "temp_export" --metadata
            BACKUP_SUCCESS=true
        else
            log "AVISO: Snapshot externo falhou, tentando método alternativo"
            BACKUP_SUCCESS=false
        fi
    else
        log "Disco não é um arquivo regular ou é um snapshot. Usando método alternativo."
        BACKUP_SUCCESS=false
    fi
    
    # Se o snapshot externo falhou, usar método de cópia direta
    if [ "$BACKUP_SUCCESS" != "true" ]; then
        log "Usando exportação direta do disco..."
        
        # Verificar se a VM está em execução e pausar se necessário
        VM_WAS_RUNNING=0
        if is_vm_running "$VM_NAME"; then
            VM_WAS_RUNNING=1
            log "VM está em execução. Pausando temporariamente..."
            virsh suspend "$VM_NAME"
            sleep 2  # Pequena pausa para garantir que a suspensão seja completa
        fi
        
        # Fazer cópia direta
        log "Copiando de $DISK_PATH para $BACKUP_FILE..."
        if cp "$DISK_PATH" "$BACKUP_FILE" 2>/dev/null; then
            log "Cópia direta concluída com sucesso"
            BACKUP_SUCCESS=true
        else
            log "ERRO: Falha na cópia direta do disco"
            BACKUP_SUCCESS=false
        fi
        
        # Resumir VM se estava em execução
        if [ $VM_WAS_RUNNING -eq 1 ]; then
            log "Resumindo VM..."
            virsh resume "$VM_NAME"
            sleep 1
        fi
    fi
    
    # Verificar se o backup foi bem-sucedido
    if [ "$BACKUP_SUCCESS" = "true" ]; then
        # Remover o checkpoint original após exportação bem-sucedida
        virsh snapshot-delete --domain "$VM_NAME" --snapshotname "$CHECKPOINT_NAME" --metadata 2>/dev/null || true
        
        # Verificar e remover qualquer arquivo de RAM temporário
        if [ "$KEEP_RAM" = "true" ] && [ -f "/var/lib/libvirt/qemu/ram/${VM_NAME}_${CHECKPOINT_NAME}.ram" ]; then
            rm -f "/var/lib/libvirt/qemu/ram/${VM_NAME}_${CHECKPOINT_NAME}.ram"
            log "Arquivo de RAM temporário removido"
        fi
        
        log "Backup com checkpoint concluído com sucesso: $BACKUP_FILE"
        log "Tamanho do backup: $(du -h "$BACKUP_FILE" | cut -f1)"
        send_notification "$CONFIG_FILE" "info" "Backup com checkpoint concluído: $(du -h "$BACKUP_FILE" | cut -f1)"
        
        # Compactar o backup
        log "Compactando o arquivo de backup..."
        if gzip -f "$BACKUP_FILE"; then
            log "Compactação concluída: ${BACKUP_FILE}.gz"
            
            # Verificar integridade 
            log "Verificando integridade do backup..."
            if gzip -t "${BACKUP_FILE}.gz"; then
                log "Verificação de integridade concluída com sucesso"
                
                # Limpar backups de checkpoint antigos (mais antigos que RETENTION_DAYS dias)
                log "Removendo backups de checkpoint mais antigos que $RETENTION_DAYS dias..."
                find "$BACKUP_DIR" -name "${VM_NAME}-checkpoint-*.gz" -type f -mtime +$RETENTION_DAYS -delete
                
                # Limpar arquivos de RAM antigos que podem ter ficado para trás
                if [ "$KEEP_RAM" = "true" ]; then
                    log "Removendo arquivos de RAM temporários antigos..."
                    find "/var/lib/libvirt/qemu/ram" -name "${VM_NAME}_*.ram" -type f -mtime +1 -delete
                fi
                
                log "====== BACKUP COM CHECKPOINT CONCLUÍDO COM SUCESSO ======"
                exit 0
            else
                log "ERRO: Verificação de integridade falhou"
                send_notification "$CONFIG_FILE" "error" "Falha na verificação de integridade do backup"
                exit 1
            fi
        else
            log "ERRO: Falha na compactação do backup"
            send_notification "$CONFIG_FILE" "error" "Falha na compactação do backup"
            exit 1
        fi
    else
        log "ERRO: Falha ao exportar checkpoint para backup"
        send_notification "$CONFIG_FILE" "error" "Falha ao exportar checkpoint para backup"
        exit 1
    fi
else
    log "ERRO: Falha ao criar checkpoint para backup"
    send_notification "$CONFIG_FILE" "error" "Falha ao criar checkpoint para backup"
    exit 1
fi
