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

# Função aprimorada para obter o caminho do disco, com suporte a discos em checkpoint
get_disk_path() {
    local vm_name="$1"
    local disk_name="$2"
    
    # Primeiro, obter informações completas sobre o disco
    log "DEBUG: Obtendo informações detalhadas do disco $disk_name para VM $vm_name"
    
    # Obter o caminho do disco diretamente via domblklist
    local current_disk_path=$(virsh domblklist "$vm_name" | grep "$disk_name" | awk '{print $2}')
    
    # Se for um caminho válido e conter "checkpoint" no nome, marcar como um snapshot/checkpoint
    if [ -n "$current_disk_path" ] && [ "$current_disk_path" != "-" ]; then
        if [[ "$current_disk_path" == *"checkpoint"* ]]; then
            log "DEBUG: Detectado que a VM está rodando a partir de um checkpoint: $current_disk_path"
            echo "CHECKPOINT:$current_disk_path"
            return 0
        elif [ -f "$current_disk_path" ]; then
            log "DEBUG: Caminho de disco regular encontrado: $current_disk_path"
            echo "$current_disk_path"
            return 0
        fi
    fi
    
    # Se falhar, tentar outros métodos
    # Armazenar XML da VM em arquivo temporário para análise
    virsh dumpxml "$vm_name" > /tmp/vm_dumpxml.txt 2>/dev/null
    
    # Tentar extrair o caminho do arquivo de uma forma diferente
    local source_file=$(grep -A10 "<target dev=\"$disk_name\"" /tmp/vm_dumpxml.txt | grep -oP 'file="\K[^"]+')
    
    if [ -n "$source_file" ]; then
        if [[ "$source_file" == *"checkpoint"* ]]; then
            log "DEBUG: Detectado via XML que a VM está rodando a partir de um checkpoint: $source_file"
            echo "CHECKPOINT:$source_file"
            rm -f /tmp/vm_dumpxml.txt
            return 0
        elif [ -f "$source_file" ]; then
            log "DEBUG: Caminho de arquivo via XML encontrado: $source_file"
            echo "$source_file"
            rm -f /tmp/vm_dumpxml.txt
            return 0
        fi
    fi
    
    # Último recurso: caminho padrão baseado no nome da VM
    log "DEBUG: Tentando caminhos padrão baseados no nome da VM"
    for path in "/var/lib/libvirt/images/${vm_name}.qcow2" "/var/lib/libvirt/images/${vm_name}.img"; do
        if [ -f "$path" ]; then
            log "DEBUG: Arquivo encontrado em caminho padrão: $path"
            echo "$path"
            rm -f /tmp/vm_dumpxml.txt 2>/dev/null
            return 0
        fi
    done
    
    # Se chegamos aqui, não foi possível encontrar o caminho
    log "ERRO: Não foi possível determinar o caminho do disco para VM $vm_name"
    rm -f /tmp/vm_dumpxml.txt 2>/dev/null
    return 1
}


# Verificar espaço em disco
check_disk_space() {
    local config_file="$1"
    local vm_name="$2"
    local backup_dir="$3"
    local vm_file="$4"
    
    # Para backup completo, precisamos de espaço suficiente para todo o arquivo
    # Usando du -h (human-readable) e grep para extrair o tamanho em GB
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

# Função para limpar checkpoints órfãos
clean_orphaned_snapshots() {
    local vm_name="$1"
    log "Verificando snapshots órfãos para limpeza..."
    
    # Listar todos os snapshots existentes
    local snapshots=$(virsh snapshot-list --domain "$vm_name" --name 2>/dev/null)
    
    if [ -n "$snapshots" ]; then
        # Checar se existem snapshots temporários
        for snap in $snapshots; do
            # Verificar se é um snapshot temporário
            if [[ "$snap" == temp_export* ]]; then
                log "Removendo snapshot temporário: $snap"
                virsh snapshot-delete --domain "$vm_name" --snapshotname "$snap" --metadata 2>/dev/null || true
            fi
        done
        
        # Remover snapshots antigos baseado na data no nome
        for snap in $snapshots; do
            if [[ "$snap" == *_checkpoint_* ]]; then
                # Extrair a data do nome (formato: VM_checkpoint_YYYYMMDD_HHMMSS)
                local date_part=$(echo "$snap" | grep -o "[0-9]\{8\}_[0-9]\{6\}" || echo "")
                
                if [ -n "$date_part" ]; then
                    # Extrair data (YYYYMMDD)
                    local snap_date="${date_part:0:8}"
                    local current_date=$(date +%Y%m%d)
                    
                    # Data atual em formato numérico para comparação
                    local current_num=$(date +%Y%m%d)
                    # Calcular diferença aproximada em dias
                    # Se a data do snapshot for de mais de 7 dias atrás, remover
                    if [ $((current_num - snap_date)) -gt 700 ]; then  # 7 dias * 100 (para simplificar)
                        log "Removendo snapshot antigo: $snap (mais de 7 dias)"
                        virsh snapshot-delete --domain "$vm_name" --snapshotname "$snap" --metadata 2>/dev/null || true
                    fi
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
    
    # Verificar se a VM suporta snapshot externo
    local vm_file_info=$(virsh domblklist "$vm_name" | grep vda | awk '{print $2}')
    local is_regular_file=true
    
    # Verificar se o arquivo do disco é um arquivo regular
    if [ -n "$vm_file_info" ] && [ ! -f "$vm_file_info" ]; then
        log "AVISO: O disco da VM não é um arquivo regular. Usando snapshot interno."
        is_regular_file=false
    fi
    
    # Se a VM estiver em execução, usar checkpoint live
    if is_vm_running "$vm_name"; then
        # Preparar para checkpoint - ações para consistência
        log "Preparando VM para checkpoint consistente"
        
        # Tentar congelar o sistema de arquivos se tiver guest agent
        virsh qemu-agent-command "$vm_name" '{"execute":"guest-fsfreeze-freeze"}' &>/dev/null || true
        
        # Criar checkpoint
        if [ "$keep_ram" = "true" ] && [ "$is_regular_file" = "true" ]; then
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
            # Snapshot interno se não for arquivo regular ou não precisar de RAM
            virsh snapshot-create-as --domain "$vm_name" \
                --name "$checkpoint_name" \
                --description "Checkpoint diário para backup incremental" \
                --atomic \
                --live
        fi
            
        # Descongelar o sistema de arquivos
        virsh qemu-agent-command "$vm_name" '{"execute":"guest-fsfreeze-thaw"}' &>/dev/null || true
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

      
# Função corrigida para exportar checkpoint
export_checkpoint() {
    local vm_name="$1"
    local disk_name="$2"
    local backup_file="$3"
    local checkpoint_name="$4"
    
    log "Verificando tipo de disco para exportação..."
    local disk_path=$(get_disk_path "$vm_name" "$disk_name")
    
    # Verificar se obtivemos um caminho válido
    if [ -z "$disk_path" ]; then
        log "ERRO: Não foi possível obter o caminho do disco '$disk_name'"
        return 1
    fi
    
    log "Caminho do disco principal: $disk_path"
    
    # Verificar se o caminho do disco existe
    if [ ! -e "$disk_path" ]; then
        log "ERRO: O arquivo de disco não existe em: $disk_path"
        return 1
    fi
    
    # Verificar se o caminho do disco é um arquivo regular
    if [ -f "$disk_path" ] && [[ "$disk_path" != *"checkpoint"* ]]; then
        log "Disco é um arquivo regular. Tentando criar snapshot externo..."
        
        # Tentar criar snapshot externo
        virsh snapshot-create-as --domain "$vm_name" \
            --name "temp_export" \
            --diskspec "$disk_name,snapshot=external,file=$backup_file" \
            --atomic \
            --disk-only
            
        if [ $? -eq 0 ]; then
            log "Snapshot externo criado com sucesso"
            
            # Remover o snapshot temporário mantendo o arquivo
            virsh snapshot-delete --domain "$vm_name" --snapshotname "temp_export" --metadata 2>/dev/null || true
            return 0
        else
            log "ERRO: Falha ao criar snapshot externo. Tentando método alternativo..."
        fi
    fi
    
    # Método alternativo: exportar o disco diretamente
    log "Usando exportação direta do disco..."
    
    # Verificar se a VM está rodando
    local vm_running=0
    if is_vm_running "$vm_name"; then
        vm_running=1
        log "VM está em execução. Pausando temporariamente para exportação..."
        virsh suspend "$vm_name"
        sleep 2  # Pequena pausa para garantir que a suspensão seja completa
    fi
    
    # Criar diretório de backup se não existir
    local backup_dir=$(dirname "$backup_file")
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
    fi
    
    # Copiar o disco - usando o caminho correto do disco
    log "Copiando de $disk_path para $backup_file..."
    if cp "$disk_path" "$backup_file"; then
        log "Exportação direta concluída com sucesso"
        
        if [ $vm_running -eq 1 ]; then
            log "Resumindo VM..."
            virsh resume "$vm_name"
        fi
        
        return 0
    else
        log "ERRO: Falha na exportação direta do disco"
        
        if [ $vm_running -eq 1 ]; then
            log "Resumindo VM após falha..."
            virsh resume "$vm_name"
        fi
        
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

# Função para backup de VM com LVM
backup_lvm_disk() {
    local vm_name="$1"
    local lvm_path="$2"
    local backup_file="$3"
    
    log "Iniciando backup especializado para disco LVM: $lvm_path"
    
    # Criar diretório de backup se não existir
    local backup_dir=$(dirname "$backup_file")
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
    fi
    
    # Verificar se a VM está rodando
    local vm_was_running=0
    if is_vm_running "$vm_name"; then
        vm_was_running=1
        log "VM está em execução. Pausando temporariamente para snapshot LVM..."
        virsh suspend "$vm_name"
        sleep 2
    fi
    
    # Obter informações do volume LVM
    local vg_name=$(lvs --noheadings -o vg_name "$lvm_path" 2>/dev/null | tr -d ' ')
    local lv_name=$(lvs --noheadings -o lv_name "$lvm_path" 2>/dev/null | tr -d ' ')
    
    if [ -z "$vg_name" ] || [ -z "$lv_name" ]; then
        log "ERRO: Não foi possível obter informações do volume LVM"
        if [ $vm_was_running -eq 1 ]; then
            virsh resume "$vm_name"
        fi
        return 1
    fi
    
    log "Volume LVM detectado: VG=$vg_name, LV=$lv_name"
    
    # Criar snapshot LVM temporário
    local snap_name="${lv_name}_snap_$(date +%s)"
    local snap_size="5G"  # Tamanho do snapshot - ajustar conforme necessário
    
    log "Criando snapshot LVM: $snap_name com tamanho $snap_size"
    if ! lvcreate -s -n "$snap_name" -L "$snap_size" "$vg_name/$lv_name"; then
        log "ERRO: Falha ao criar snapshot LVM"
        if [ $vm_was_running -eq 1 ]; then
            virsh resume "$vm_name"
        fi
        return 1
    fi
    
    # Resumir VM se estava em execução
    if [ $vm_was_running -eq 1 ]; then
        log "Resumindo VM após criar snapshot LVM..."
        virsh resume "$vm_name"
    fi
    
    local snap_path="/dev/$vg_name/$snap_name"
    log "Snapshot LVM criado: $snap_path"
    
    # Exportar o snapshot para o arquivo de backup
    log "Exportando snapshot LVM para $backup_file..."
    if dd if="$snap_path" of="$backup_file" bs=8M status=progress; then
        log "Exportação do snapshot LVM concluída com sucesso"
        # Remover o snapshot
        log "Removendo snapshot LVM temporário..."
        lvremove -f "$vg_name/$snap_name"
        return 0
    else
        log "ERRO: Falha ao exportar snapshot LVM"
        # Remover o snapshot em caso de falha
        log "Removendo snapshot LVM temporário após falha..."
        lvremove -f "$vg_name/$snap_name"
        return 1
    fi
}

# Função para backup de VM rodando a partir de um checkpoint
backup_checkpointed_disk() {
    local vm_name="$1"
    local checkpoint_path="$2"
    local backup_file="$3"
    
    log "Iniciando backup especializado para VM rodando a partir de checkpoint: $checkpoint_path"
    
    # Criar diretório de backup se não existir
    local backup_dir=$(dirname "$backup_file")
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
    fi
    
    # Tentar obter o arquivo base original da VM
    local original_file=""
    local base_info=$(qemu-img info --backing-chain "$checkpoint_path" 2>/dev/null | grep "backing file:" | head -1)
    
    if [ -n "$base_info" ]; then
        original_file=$(echo "$base_info" | sed -E 's/backing file: (.*)/\1/' | sed -E 's/ \(.*\)//')
        log "Arquivo base identificado: $original_file"
    else
        # Tentar outro método para identificar o original
        original_file="/var/lib/libvirt/images/${vm_name}.qcow2"
        if [ -f "$original_file" ]; then
            log "Usando arquivo original por convenção de nomenclatura: $original_file"
        else
            log "AVISO: Não foi possível determinar o arquivo original, tentando backup direto"
            original_file=""
        fi
    fi
    
    # Decidir a estratégia a ser usada
    if [ -n "$original_file" ] && [ -f "$original_file" ]; then
        # Se temos o arquivo original, podemos tentar criar um novo checkpoint a partir dele
        log "Estratégia: Criar novo checkpoint a partir do arquivo base"
        
        # Verificar se a VM está rodando
        local vm_was_running=0
        if is_vm_running "$vm_name"; then
            vm_was_running=1
            log "VM está em execução. Pausando temporariamente..."
            virsh suspend "$vm_name"
            sleep 2
        fi
        
        # Copiar o arquivo original para o novo backup
        log "Copiando arquivo original para backup: $original_file -> $backup_file"
        if cp "$original_file" "$backup_file"; then
            log "Cópia do arquivo original concluída com sucesso"
            
            if [ $vm_was_running -eq 1 ]; then
                log "Resumindo VM..."
                virsh resume "$vm_name"
            fi
            
            return 0
        else
            log "ERRO: Falha ao copiar arquivo original"
            
            if [ $vm_was_running -eq 1 ]; then
                log "Resumindo VM após falha..."
                virsh resume "$vm_name"
            fi
            
            return 1
        fi
    else
        # Se não temos o arquivo original, tentar método alternativo com qemu-img
        log "Estratégia: Usar qemu-img para criar um novo snapshot sem dependências"
        
        # Verificar se a VM está rodando
        local vm_was_running=0
        if is_vm_running "$vm_name"; then
            vm_was_running=1
            log "VM está em execução. Pausando temporariamente..."
            virsh suspend "$vm_name"
            sleep 2
        fi
        
        # Criar novo snapshot consolidado usando qemu-img
        log "Criando snapshot consolidado usando qemu-img..."
        if qemu-img create -f qcow2 -b "$checkpoint_path" "$backup_file"; then
            log "Snapshot consolidado criado: $backup_file"
            
            if [ $vm_was_running -eq 1 ]; then
                log "Resumindo VM..."
                virsh resume "$vm_name"
            fi
            
            # Realizar rebase para remover dependências
            log "Realizando rebase para remover dependências..."
            if qemu-img rebase -f qcow2 -b "" "$backup_file"; then
                log "Rebase concluído com sucesso, arquivo independente criado"
                return 0
            else
                log "ERRO: Falha no rebase. O backup pode ter dependências"
                return 1
            fi
        else
            log "ERRO: Falha ao criar snapshot consolidado"
            
            if [ $vm_was_running -eq 1 ]; then
                log "Resumindo VM após falha..."
                virsh resume "$vm_name"
            fi
            
            return 1
        fi
    fi
}
