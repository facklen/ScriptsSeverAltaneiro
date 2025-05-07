#!/bin/bash
#
# vm_backup_utils.sh - Funções utilitárias simplificadas para backup de VMs
#
# Contém funções comuns utilizadas pelo script principal de backup
# Versão simplificada sem lógica de checkpoints

# Carrega YAML (requer 'yq')
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
    
    # Configurações para backup offline
    BACKUP_DIR="${BACKUP_BASE_DIR}/${VM_NAME}/full"
    DEFAULT_RETENTION=$(get_config "$config_file" '.default_retention.weekly' "8")
    RETENTION_COUNT=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "offline") | .retention_count' "$DEFAULT_RETENTION")
    SHUTDOWN_TIMEOUT=$(get_config "$config_file" '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "offline") | .shutdown_timeout' "600")
    
    LOG_FILE="${LOG_DIR}/backup_${VM_NAME}_full.log"
    BACKUP_FILE="${BACKUP_DIR}/${VM_NAME}-full-$(date +%Y%m%d_%H%M%S).qcow2"
    
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
    export RETENTION_COUNT SHUTDOWN_TIMEOUT
    
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

# Verificar espaço em disco
check_disk_space() {
    local config_file="$1"
    local vm_name="$2"
    local backup_dir="$3"
    local vm_file="$4"
    
    # Para backup completo, precisamos de espaço suficiente para todo o arquivo
    local vm_size=$(du -h "$vm_file" | awk '{print $1}' | grep -o '[0-9.]*' | head -1)
    # Convertendo para um número inteiro para facilitar comparações
    vm_size=$(echo "$vm_size" | cut -d. -f1)
    if [ -z "$vm_size" ]; then vm_size=1; fi

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
