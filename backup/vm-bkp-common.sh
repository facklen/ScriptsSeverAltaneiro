#!/bin/bash
#
# vm_backup_common.sh - Funções compartilhadas para scripts de backup de VM
#
# Este arquivo contém funções comuns utilizadas pelos scripts de backup
# Deve ser incluído (source) nos scripts principais

# Carrega YAML
# Requer o comando 'yq' (instale com: apt install yq)
load_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo "ERRO: Arquivo de configuração não encontrado: $config_file"
        return 1
    fi
    
    if ! command -v yq &> /dev/null; then
        echo "ERRO: Comando 'yq' não encontrado. Instale com: sudo apt install yq"
        return 1
    fi
    
    return 0
}

# Obtém parâmetro do arquivo de configuração
get_config() {
    local config_file="$1"
    local param="$2"
    local default="$3"
    
    local value=$(yq eval "$param" "$config_file")
    
    if [ "$value" = "null" ] || [ -z "$value" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Configura variáveis de ambiente para a VM especificada
setup_vm_env() {
    local config_file="$1"
    local vm_name="$2"
    local backup_type="$3"
    
    # Verificar se a VM existe na configuração
    local vm_exists=$(yq eval '.vms[] | select(.name == "'"$vm_name"'") | .name' "$config_file")
    if [ -z "$vm_exists" ]; then
        echo "ERRO: VM '$vm_name' não encontrada na configuração"
        return 1
    fi
    
    # Verificar se a VM está habilitada
    local vm_enabled=$(yq eval '.vms[] | select(.name == "'"$vm_name"'") | .enabled' "$config_file")
    if [ "$vm_enabled" != "true" ]; then
        echo "VM '$vm_name' está desabilitada na configuração"
        return 2
    fi
    
    # Verificar se o tipo de backup está habilitado para esta VM
    local backup_enabled=$(yq eval '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "'"$backup_type"'") | .enabled' "$config_file")
    if [ "$backup_enabled" != "true" ]; then
        echo "Backup do tipo '$backup_type' está desabilitado para VM '$vm_name'"
        return 3
    fi
    
    # Obter configurações globais
    BACKUP_BASE_DIR=$(get_config "$config_file" '.global.backup_base_dir' "/opt/backup")
    LOG_DIR=$(get_config "$config_file" '.global.log_dir' "/var/log")
    
    # Obter configurações da VM
    VM_NAME="$vm_name"
    VM_DESCRIPTION=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .description' "$vm_name")
    VM_FILE=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .vm_file' "")
    
    if [ -z "$VM_FILE" ]; then
        echo "ERRO: Caminho do arquivo da VM não definido"
        return 1
    fi
    
    # Configurações específicas por tipo de backup
    if [ "$backup_type" = "checkpoint" ]; then
        BACKUP_DIR="${BACKUP_BASE_DIR}/${VM_NAME}/checkpoints"
        DEFAULT_RETENTION=$(get_config "$config_file" '.default_retention.checkpoint' "7")
        RETENTION_DAYS=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "checkpoint") | .retention_days' "$DEFAULT_RETENTION")
        # Opções especiais para checkpoint
        KEEP_RAM=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "checkpoint") | .special_options.keep_ram' "true")
        
        LOG_FILE="${LOG_DIR}/backup_${VM_NAME}_checkpoints.log"
        BACKUP_FILE="${BACKUP_DIR}/${VM_NAME}-checkpoint-$(date +%Y%m%d_%H%M%S).qcow2"
    elif [ "$backup_type" = "offline" ]; then
        BACKUP_DIR="${BACKUP_BASE_DIR}/${VM_NAME}/weekly"
        DEFAULT_RETENTION=$(get_config "$config_file" '.default_retention.weekly' "8")
        RETENTION_COUNT=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "offline") | .retention_count' "$DEFAULT_RETENTION")
        # Opções específicas para offline
        SHUTDOWN_TIMEOUT=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "offline") | .shutdown_timeout' "600")
        KEEP_LAST_CHECKPOINT=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "offline") | .special_options.keep_last_checkpoint' "false")
        
        LOG_FILE="${LOG_DIR}/backup_${VM_NAME}_weekly.log"
        BACKUP_FILE="${BACKUP_DIR}/${VM_NAME}-full-$(date +%Y%m%d_%H%M%S).qcow2"
    else
        echo "ERRO: Tipo de backup inválido: $backup_type"
        return 1
    fi
    
    # Verificar existência de diretórios
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
    fi
    
    # Verificar se o arquivo da VM existe
    if [ ! -f "$VM_FILE" ]; then
        echo "ERRO: Arquivo da VM não existe: $VM_FILE"
        return 1
    fi
    
    # Verificar se VM existe no libvirt
    if ! virsh dominfo "$VM_NAME" &> /dev/null; then
        echo "ERRO: VM $VM_NAME não existe no libvirt"
        return 1
    fi
    
    # Exportar todas as variáveis para uso nos scripts de backup
    export VM_NAME VM_DESCRIPTION VM_FILE 
    export BACKUP_DIR BACKUP_FILE LOG_FILE
    export RETENTION_DAYS RETENTION_COUNT SHUTDOWN_TIMEOUT
    export KEEP_RAM KEEP_LAST_CHECKPOINT
    
    return 0
}

# Função para logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Função para enviar notificações
send_notification() {
    local config_file="$1"
    local level="$2"  # info, warning, error, critical
    local message="$3"
    
    # Log da mensagem
    log "[NOTIFY-$level] $message"
    
    # Verificar se notificações estão habilitadas
    local notify_enabled=$(get_config "$config_file" '.global.notification.enabled' "false")
    if [ "$notify_enabled" != "true" ]; then
        return 0
    fi
    
    # Obter método de notificação
    local method=$(get_config "$config_file" '.global.notification.method' "none")
    
    case "$method" in
        email)
            local recipient=$(get_config "$config_file" '.global.notification.email.recipient' "")
            if [ -n "$recipient" ]; then
                echo "$message" | mail -s "[BACKUP-$level] VM $VM_NAME" "$recipient"
            fi
            ;;
        slack)
            # Implementar integração com Slack se necessário
            ;;
        teams)
            # Implementar integração com Teams se necessário
            ;;
        *)
            # Sem notificação
            ;;
    esac
}

# Função que verifica se a VM está em execução
is_vm_running() {
    local vm_name="$1"
    if virsh domstate "$vm_name" | grep -q "running"; then
        return 0
    else
        return 1
    fi
}

# Função para obter o nome correto do disco da VM
get_disk_name() {
    local vm_name="$1"
    
    # Método confiável usando dumpxml para encontrar o primeiro disco não-cdrom
    local disk_name=$(virsh dumpxml "$vm_name" | grep "<target dev=" | grep -v "device='cdrom'" | head -1 | sed -n "s/.*dev='\([^']*\)'.*/\1/p")
    
    # Verificar se temos um resultado válido
    if [ -z "$disk_name" ]; then
        # Método alternativo se o anterior falhar
        local disk_info=$(virsh domblklist "$vm_name" | awk 'NR>2 && $2 != "-" {print $1; exit}')
        if [ -n "$disk_info" ]; then
            disk_name="$disk_info"
        fi
    fi
    
    echo "$disk_name"
}

# Verificar espaço em disco
check_disk_space() {
    local config_file="$1"
    local vm_name="$2"
    local backup_dir="$3"
    local vm_file="$4"
    
    # Para backup completo, precisamos de espaço suficiente para todo o arquivo
    local vm_size=$(du -g "$vm_file" | cut -f1)
    local required_space=$((vm_size + 5))  # VM size + 5GB para segurança
    local available_space=$(df -BG "$backup_dir" | tail -1 | awk '{print $4}' | tr -d 'G')
    
    if [ $available_space -lt $required_space ]; then
        log "ALERTA: Espaço insuficiente para backup. Necessário: ${required_space}GB, Disponível: ${available_space}GB"
        send_notification "$config_file" "critical" "Espaço em disco insuficiente para backup de $vm_name"
        return 1
    fi
    
    log "Espaço em disco suficiente para backup: ${available_space}GB disponível"
    return 0
}

# Função para desligamento seguro da VM
safe_shutdown() {
    local config_file="$1"
    local vm_name="$2"
    local timeout="$3"
    local grace_period=30  # Tempo extra para processos críticos

    # Primeiro tenta shutdown normal via ACPI
    log "Iniciando desligamento seguro de $vm_name..."
    send_notification "$config_file" "info" "Iniciando desligamento de $vm_name para backup offline"
    virsh shutdown "$vm_name"

    # Monitorar estado da VM
    for ((i=1; i<=timeout; i++)); do
        if ! virsh domstate "$vm_name" | grep -q "running"; then
            log "VM $vm_name desligou normalmente após $i segundos"
            return 0
        fi
        
        # A cada 60 segundos, verifica e registra o progresso
        if [ $((i % 60)) -eq 0 ]; then
            log "VM ainda em execução após $i segundos. Verificando estado..."
            send_notification "$config_file" "info" "VM ainda em processo de desligamento ($i segundos decorridos)"
        fi
        
        sleep 1
    done

    # Se chegou aqui, o shutdown normal falhou
    log "Aviso: Timeout após $timeout segundos. Iniciando procedimento de emergência..."
    send_notification "$config_file" "warning" "VM não desligou dentro do tempo previsto, tentando shutdown forçado"
    
    # Tenta shutdown forçado via ACPI
    log "Tentando shutdown forçado via ACPI..."
    virsh shutdown --mode acpi "$vm_name"
    sleep $grace_period

    # Verifica uma última vez
    if ! virsh domstate "$vm_name" | grep -q "running"; then
        log "VM desligou com shutdown forçado após período de graça"
        return 0
    fi

    # Último recurso: destroy
    log "ALERTA: Shutdown forçado falhou. Executando destroy como último recurso"
    send_notification "$config_file" "critical" "Executando destroy na VM para realizar backup offline"
    virsh destroy "$vm_name"
    sleep 5

    if ! virsh domstate "$vm_name" | grep -q "running"; then
        log "VM foi desligada forçadamente usando destroy"
        return 0
    fi
    
    log "ERRO CRÍTICO: Não foi possível desligar a VM de nenhuma forma"
    return 1
}

# Função para reiniciar a VM
start_vm() {
    local config_file="$1"
    local vm_name="$2"
    
    log "Iniciando VM $vm_name após backup..."
    virsh start "$vm_name"
    
    # Aguardar até 2 minutos para VM iniciar
    for ((i=1; i<=120; i++)); do
        if virsh domstate "$vm_name" | grep -q "running"; then
            log "VM $vm_name iniciada com sucesso após backup"
            send_notification "$config_file" "info" "VM $vm_name iniciada com sucesso após backup offline"
            return 0
        fi
        sleep 1
    done
    
    log "ERRO: Falha ao iniciar VM $vm_name após backup"
    send_notification "$config_file" "error" "Falha ao iniciar VM após backup offline"
    return 1
}

# Função para limpar checkpoints órfãos
clean_orphaned_snapshots() {
    local vm_name="$1"
    log "Verificando snapshots órfãos para limpeza..."
    
    # Listar todos os snapshots existentes
    local snapshots=$(virsh snapshot-list --domain "$vm_name" --name 2>/dev/null)
    
    if [ -n "$snapshots" ]; then
        # Procurar por snapshots temporários antigos (mais de 1 dia)
        for snap in $snapshots; do
            # Verificar se é um snapshot temporário ou antigo
            if [[ "$snap" == temp_export* ]] || [[ "$snap" == *_checkpoint_* ]]; then
                # Verificar data de criação (não é 100% preciso, mas uma aproximação)
                local creation_date=$(virsh snapshot-info --domain "$vm_name" --snapshotname "$snap" | grep "Creation time" | cut -d: -f2- | xargs date +%s -d)
                local current_date=$(date +%s)
                local age_in_days=$(( (current_date - creation_date) / 86400 ))
                
                if [ "$snap" == "temp_export" ] || [ $age_in_days -gt 1 ]; then
                    log "Removendo snapshot órfão antigo: $snap"
                    virsh snapshot-delete --domain "$vm_name" --snapshotname "$snap" || true
                fi
            fi
        done
    fi
}

# Função para criar checkpoint
create_checkpoint() {
    local vm_name="$1"
    local keep_ram="$2"
    local checkpoint_name="${vm_name}_checkpoint_$(date +%Y%m%d_%H%M%S)"
    
    log "Criando checkpoint '$checkpoint_name' para $vm_name"
    
    # Se a VM estiver em execução, usar checkpoint live
    if is_vm_running "$vm_name"; then
        # Preparar para checkpoint - ações para AD consistente
        log "Preparando VM para checkpoint consistente"
        
        # Se tiver QEMU guest agent instalado, pode congelar o sistema de arquivos
        # virsh qemu-agent-command "$vm_name" '{"execute":"guest-fsfreeze-freeze"}' &>/dev/null
        
        # Criar checkpoint com memória (VM em execução)
        if [ "$keep_ram" = "true" ]; then
            # Garantir que diretório para RAM existe
            if [ ! -d "/var/lib/libvirt/qemu/ram" ]; then
                mkdir -p "/var/lib/libvirt/qemu/ram"
            fi
            
            virsh snapshot-create-as --domain "$vm_name" \
                --name "$checkpoint_name" \
                --description "Checkpoint diário para backup incremental" \
                --atomic \
                --live \
                --memspec file=/var/lib/libvirt/qemu/ram/${vm_name}_${checkpoint_name}.ram
        else
            virsh snapshot-create-as --domain "$vm_name" \
                --name "$checkpoint_name" \
                --description "Checkpoint diário para backup incremental" \
                --atomic \
                --live
        fi
            
        # Descongelar o sistema de arquivos se estiver usando guest agent
        # virsh qemu-agent-command "$vm_name" '{"execute":"guest-fsfreeze-thaw"}' &>/dev/null
    else
        # Checkpoint offline
        virsh snapshot-create-as --domain "$vm_name" \
            --name "$checkpoint_name" \
            --description "Checkpoint offline para backup incremental" \
            --atomic
    fi
    
    if [ $? -eq 0 ]; then
        log "Checkpoint '$checkpoint_name' criado com sucesso"
        echo "$checkpoint_name"  # Retorna o nome do checkpoint
    else
        log "ERRO: Falha ao criar checkpoint para $vm_name"
        return 1
    fi
}

# Função para listar todos os checkpoints
list_checkpoints() {
    local vm_name="$1"
    local checkpoints=$(virsh snapshot-list --domain "$vm_name" --name 2>/dev/null | grep -v "^$")
    
    if [ -z "$checkpoints" ]; then
        log "Nenhum checkpoint encontrado para VM $vm_name"
        return 1
    fi
    
    echo "$checkpoints"
    return 0
}

# Função para remover checkpoint
remove_checkpoint() {
    local vm_name="$1"
    local checkpoint_name="$2"
    
    log "Removendo checkpoint: $checkpoint_name"
    virsh snapshot-delete --domain "$vm_name" --snapshotname "$checkpoint_name" &>/dev/null
    
    if [ $? -eq 0 ]; then
        log "Checkpoint '$checkpoint_name' removido com sucesso"
        return 0
    else
        log "AVISO: Falha ao remover checkpoint '$checkpoint_name'"
        return 1
    fi
}

# Função para limpar todos os checkpoints
cleanup_checkpoints() {
    local config_file="$1"
    local vm_name="$2"
    local keep_last="$3"
    local backup_success="$4"
    
    if [ "$backup_success" != "true" ]; then
        log "AVISO: Backup não foi bem-sucedido. Mantendo checkpoints por segurança."
        return 1
    fi
    
    log "==== INICIANDO LIMPEZA DE CHECKPOINTS ===="
    
    # Obter lista de checkpoints
    CHECKPOINTS=$(list_checkpoints "$vm_name")
    if [ $? -ne 0 ]; then
        log "Nenhum checkpoint para remover. Finalizando limpeza."
        send_notification "$config_file" "info" "Nenhum checkpoint encontrado para limpeza"
        return 0
    fi
    
    # Contar número de checkpoints
    CHECKPOINT_COUNT=$(echo "$CHECKPOINTS" | wc -l)
    log "Encontrados $CHECKPOINT_COUNT checkpoints para remover"
    
    # Se configurado para manter o último checkpoint, guardar seu nome
    LAST_CHECKPOINT=""
    if [ "$keep_last" = "true" ] && [ $CHECKPOINT_COUNT -gt 0 ]; then
        LAST_CHECKPOINT=$(echo "$CHECKPOINTS" | tail -n 1)
        log "Mantendo o checkpoint mais recente: $LAST_CHECKPOINT"
    fi
    
    # Remover os checkpoints
    REMOVED=0
    FAILED=0
    
    for checkpoint in $CHECKPOINTS; do
        # Se estiver configurado para manter o último checkpoint e este for o último, pular
        if [ "$keep_last" = "true" ] && [ "$checkpoint" = "$LAST_CHECKPOINT" ]; then
            log "Preservando checkpoint mais recente: $checkpoint"
            continue
        fi
        
        if remove_checkpoint "$vm_name" "$checkpoint"; then
            REMOVED=$((REMOVED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    done
    
    # Resumir operação
    log "Resumo da limpeza: $REMOVED checkpoints removidos, $FAILED falhas"
    
    if [ $FAILED -gt 0 ]; then
        send_notification "$config_file" "warning" "Limpeza de checkpoints concluída com $FAILED falhas. $REMOVED checkpoints removidos com sucesso."
    else
        send_notification "$config_file" "info" "Limpeza de checkpoints concluída com sucesso. $REMOVED checkpoints removidos."
    fi
    
    log "==== LIMPEZA DE CHECKPOINTS CONCLUÍDA ===="
    return 0
}
