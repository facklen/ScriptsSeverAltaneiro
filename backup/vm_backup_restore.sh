#!/bin/bash
#
# vm_backup_restore.sh - Script para backup de VMs com restauração do arquivo original
# Uso: sudo ./vm_backup_restore.sh /caminho/para/config.yaml [nome_vm]
#
# Realiza backups completos offline de VMs e restaura o arquivo original

# Verificar argumentos
if [ $# -lt 1 ]; then
    echo "Uso: $0 <arquivo_config> [nome_vm]"
    exit 1
fi

CONFIG_FILE="$1"
TARGET_VM="${2:-all}"  # Se não for especificado, faz backup de todas as VMs

# Verificar se o script está rodando como root
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: Execute este script como root (sudo)"
    exit 1
fi

# Carregar utilitários compartilhados
source $(dirname "$(readlink -f "$0")")/vm_backup_utils.sh

# Verificar e carregar configuração
if ! load_config "$CONFIG_FILE"; then
    exit 1
fi

# Função para determinar caminho padrão no libvirt
get_libvirt_path() {
    local vm_name="$1"
    
    # Tenta obter o caminho padrão para a VM baseado na convenção do libvirt
    local default_path="/var/lib/libvirt/images/${vm_name}.qcow2"
    
    # Se o arquivo padrão existe, retorna ele
    if [ -f "$default_path" ]; then
        echo "$default_path"
        return 0
    fi
    
    # Se não, tenta verificar outros formatos de arquivo
    local alt_paths=(
        "/var/lib/libvirt/images/${vm_name}.img"
        "/var/lib/libvirt/images/${vm_name}.raw"
        "/var/lib/libvirt/images/${vm_name}_disk.qcow2"
    )
    
    for path in "${alt_paths[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    # Se não conseguiu encontrar nenhum caminho padrão, retorna vazio
    echo ""
    return 1
}

# Função para realizar backup offline de uma VM
backup_vm() {
    local config_file="$1"
    local vm_name="$2"
    
    echo "==== Iniciando backup para VM '$vm_name' ===="
    
    # Configurar ambiente para a VM
    setup_vm_env "$config_file" "$vm_name"
    if [ $? -ne 0 ]; then
        echo "ERRO: Falha ao configurar ambiente para VM '$vm_name'"
        return 1
    fi
    
    # Registrar início do backup no log
    log "====== INICIANDO BACKUP OFFLINE PARA $VM_NAME ======"
    send_notification "$config_file" "info" "Iniciando backup offline para $VM_NAME"
    
    # Verificar espaço em disco
    if ! check_disk_space "$config_file" "$VM_NAME" "$BACKUP_DIR" "$VM_FILE"; then
        log "ERRO: Abortando backup por falta de espaço"
        send_notification "$config_file" "critical" "Backup abortado: Espaço insuficiente para $VM_NAME"
        return 1
    fi
    
    # Obter informações sobre o arquivo original da VM no libvirt
    ORIGINAL_VM_PATH=$(get_libvirt_path "$VM_NAME")
    log "Caminho original da VM no libvirt: $ORIGINAL_VM_PATH"
    
    # Se não conseguiu determinar o caminho original, alertar mas continuar
    if [ -z "$ORIGINAL_VM_PATH" ]; then
        log "AVISO: Não foi possível determinar o caminho original da VM no libvirt"
        log "A VM continuará usando o arquivo de backup após reiniciar"
        RESTORE_ORIGINAL=false
    else
        RESTORE_ORIGINAL=true
        # Verificar se o diretório para backup do arquivo original existe
        ORIGINAL_BACKUP_DIR="${BACKUP_DIR}/original_backups"
        if [ ! -d "$ORIGINAL_BACKUP_DIR" ]; then
            mkdir -p "$ORIGINAL_BACKUP_DIR"
            log "Criado diretório para backups do arquivo original: $ORIGINAL_BACKUP_DIR"
        fi
    fi
    
    # Verificar se VM está rodando e desligar se necessário
    VM_WAS_RUNNING=0
    if is_vm_running "$VM_NAME"; then
        VM_WAS_RUNNING=1
        log "VM está em execução. Iniciando procedimento de desligamento seguro."
        
        if ! safe_shutdown "$config_file" "$VM_NAME" "$SHUTDOWN_TIMEOUT"; then
            log "ERRO CRÍTICO: Falha no desligamento da VM. Abortando backup."
            send_notification "$config_file" "critical" "Backup abortado - falha no desligamento da VM"
            return 1
        fi
    else
        log "VM já está desligada. Prosseguindo com backup."
    fi
    
    # Realizar o backup completo
    log "Iniciando backup offline completo..."
    if rsync -ah --progress "$VM_FILE" "$BACKUP_FILE"; then
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
                
                # Manter apenas os últimos N backups
                log "Removendo backups antigos (mantendo os últimos $RETENTION_COUNT)..."
                find "$BACKUP_DIR" -name "${VM_NAME}-full-*.gz" -type f | sort -r | tail -n +$((RETENTION_COUNT+1)) | xargs --no-run-if-empty rm -f
                
                # Calcular tamanho total dos backups
                TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
                log "Tamanho total dos backups armazenados: $TOTAL_SIZE"
                
                send_notification "$config_file" "info" "Backup offline concluído com sucesso. Tamanho: $(du -h "${BACKUP_FILE}.gz" | cut -f1)"
                
                # Descomprimir o backup para restauração
                log "Descomprimindo o backup para restaurar o arquivo original..."
                gunzip -f "${BACKUP_FILE}.gz"
                
                # Atualizar o arquivo original no libvirt, se possível
                if [ "$RESTORE_ORIGINAL" = true ] && [ -f "$BACKUP_FILE" ]; then
                    log "Restaurando o arquivo original no libvirt..."
                    
                    # Backup do arquivo original antes de substituir
                    ORIGINAL_BACKUP="${ORIGINAL_BACKUP_DIR}/${VM_NAME}-original-$(date +%Y%m%d_%H%M%S).qcow2"
                    log "Fazendo backup do arquivo original: $ORIGINAL_VM_PATH -> $ORIGINAL_BACKUP"
                    
                    if cp -a "$ORIGINAL_VM_PATH" "$ORIGINAL_BACKUP"; then
                        log "Backup do arquivo original concluído com sucesso"
                        
                        # Atualizar o arquivo original com o novo backup
                        log "Atualizando arquivo original: $BACKUP_FILE -> $ORIGINAL_VM_PATH"
                        if cp -a "$BACKUP_FILE" "$ORIGINAL_VM_PATH"; then
                            log "Arquivo original atualizado com sucesso"
                            
                            # Garantir permissões corretas
                            chown libvirt-qemu:libvirt-qemu "$ORIGINAL_VM_PATH" || true
                            
                            # Recomprimir o backup após restauração
                            log "Recomprimindo o backup após restauração..."
                            gzip -f "$BACKUP_FILE"
                        else
                            log "ERRO: Falha ao atualizar arquivo original"
                            send_notification "$config_file" "error" "Falha ao atualizar arquivo original. A VM iniciará a partir do arquivo atual."
                            # Recomprimir o backup mesmo após falha
                            gzip -f "$BACKUP_FILE"
                        fi
                    else
                        log "ERRO: Falha ao fazer backup do arquivo original"
                        send_notification "$config_file" "error" "Falha ao fazer backup do arquivo original. Abortando restauração."
                        # Recomprimir o backup
                        gzip -f "$BACKUP_FILE"
                    fi
                else
                    log "Não é possível restaurar o arquivo original. A VM iniciará a partir do arquivo atual."
                    # Recomprimir o backup
                    if [ -f "$BACKUP_FILE" ]; then
                        gzip -f "$BACKUP_FILE"
                    fi
                fi
            else
                log "AVISO: Verificação de integridade falhou!"
                send_notification "$config_file" "warning" "Verificação de integridade do backup falhou"
                BACKUP_SUCCESS=false
            fi
        else
            log "AVISO: Falha na compactação do arquivo de backup"
            send_notification "$config_file" "warning" "Falha na compactação do arquivo de backup"
            BACKUP_SUCCESS=false
        fi
    else
        log "ERRO: Falha no backup offline da VM"
        send_notification "$config_file" "critical" "Falha no backup offline completo - erro na cópia do arquivo"
        
        # Se falhar, remover arquivo parcial se existir
        [ -f "$BACKUP_FILE" ] && rm -f "$BACKUP_FILE"
        BACKUP_SUCCESS=false
    fi
    
    # Reiniciar a VM se estava rodando antes
    if [ $VM_WAS_RUNNING -eq 1 ]; then
        log "VM estava em execução antes do backup. Reiniciando..."
        
        if ! start_vm "$config_file" "$VM_NAME"; then
            log "AVISO: Não foi possível reiniciar a VM automaticamente!"
            send_notification "$config_file" "warning" "VM não reiniciou automaticamente após backup"
            return 1
        fi
    else
        log "VM não estava em execução antes do backup. Mantendo desligada."
    fi
    
    if [ "$BACKUP_SUCCESS" = true ]; then
        log "====== BACKUP OFFLINE CONCLUÍDO COM SUCESSO ======"
        return 0
    else
        log "====== BACKUP OFFLINE CONCLUÍDO COM FALHAS ======"
        return 1
    fi
}

# Processar todas as VMs ou apenas a especificada
process_backups() {
    local config_file="$1"
    local target_vm="$2"
    
    # Se target_vm não for "all", fazer backup apenas da VM especificada
    if [ "$target_vm" != "all" ]; then
        # Verificar se a VM existe na configuração
        local vm_exists=$(yq eval '.vms[] | select(.name == "'"$target_vm"'") | .name' "$config_file")
        if [ -z "$vm_exists" ]; then
            echo "ERRO: VM '$target_vm' não encontrada na configuração"
            return 1
        fi
        
        # Verificar se a VM está habilitada
        local vm_enabled=$(yq eval '.vms[] | select(.name == "'"$target_vm"'") | .enabled' "$config_file")
        if [ "$vm_enabled" != "true" ]; then
            echo "VM '$target_vm' está desabilitada na configuração"
            return 0
        fi
        
        # Fazer backup da VM especificada
        backup_vm "$config_file" "$target_vm"
    else
        # Processar todas as VMs habilitadas
        local vms=$(yq eval '.vms[] | select(.enabled == true) | .name' "$config_file")
        
        if [ -z "$vms" ]; then
            echo "Nenhuma VM habilitada encontrada na configuração"
            return 0
        fi
        
        # Para cada VM habilitada, fazer o backup
        for vm in $vms; do
            backup_vm "$config_file" "$vm"
        done
    fi
    
    return 0
}

# Executar backups conforme os parâmetros especificados
echo "====== INICIANDO GERENCIADOR DE BACKUPS DE VMs COM RESTAURAÇÃO ======"
echo "Arquivo de configuração: $CONFIG_FILE"
echo "VM alvo: $TARGET_VM"

process_backups "$CONFIG_FILE" "$TARGET_VM"
result=$?

echo "====== GERENCIADOR DE BACKUPS DE VMs CONCLUÍDO ======"
exit $result
