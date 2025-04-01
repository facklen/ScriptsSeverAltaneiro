#!/bin/bash
#
# vm_backup_manager.sh - Script principal para gerenciar backups de VMs
# Uso: sudo ./vm_backup_manager.sh /caminho/para/config.yaml [checkpoint|offline] [nome_vm]
#
# Gerencia backups de múltiplas VMs conforme configuração
# Se nome_vm for fornecido, faz backup apenas desta VM

# Verificar argumentos
if [ $# -lt 1 ]; then
    echo "Uso: $0 <arquivo_config> [checkpoint|offline] [nome_vm]"
    exit 1
fi

CONFIG_FILE="$1"
BACKUP_TYPE="${2:-all}"  # Se não for especificado, faz ambos os tipos
TARGET_VM="${3:-all}"     # Se não for especificado, faz backup de todas as VMs

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

# Função para fazer backup de uma VM específica
backup_vm() {
    local config_file="$1"
    local vm_name="$2"
    local backup_type="$3"
    
    echo "==== Iniciando backup do tipo '$backup_type' para VM '$vm_name' ===="
    
    case "$backup_type" in
        checkpoint)
            # Verificar se o backup por checkpoint está habilitado para esta VM
            local checkpoint_enabled=$(yq eval '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "checkpoint") | .enabled' "$config_file")
            if [ "$checkpoint_enabled" != "true" ]; then
                echo "Backup do tipo 'checkpoint' está desabilitado para VM '$vm_name'"
                return 0
            fi
            
            if [ -f "${SCRIPT_DIR}/bkp-checkpoint-script.sh" ]; then
                ${SCRIPT_DIR}/bkp-checkpoint-script.sh "$config_file" "$vm_name"
            else
                echo "ERRO: Script de backup por checkpoint não encontrado"
                return 1
            fi
            ;;
            
        offline)
            # Verificar se o backup offline está habilitado para esta VM
            local offline_enabled=$(yq eval '.vms[] | select(.name == "'"$vm_name"'") | .backup_types[] | select(.type == "offline") | .enabled' "$config_file")
            if [ "$offline_enabled" != "true" ]; then
                echo "Backup do tipo 'offline' está desabilitado para VM '$vm_name'"
                return 0
            fi
            
            if [ -f "${SCRIPT_DIR}/bkp-offline-script.sh" ]; then
                ${SCRIPT_DIR}/bkp-offline-script.sh.sh "$config_file" "$vm_name"
            else
                echo "ERRO: Script de backup offline não encontrado"
                return 1
            fi
            ;;
            
        *)
            echo "ERRO: Tipo de backup inválido: $backup_type"
            return 1
            ;;
    esac
    
    return $?
}

# Função para processar todos os backups
process_all_backups() {
    local config_file="$1"
    local backup_type="$2"
    local target_vm="$3"
    
    # Se target_vm não for "all", verificar se a VM existe e está habilitada
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
        
        # Fazer backup apenas da VM especificada
        if [ "$backup_type" = "all" ]; then
            # Fazer ambos os tipos de backup
            backup_vm "$config_file" "$target_vm" "checkpoint"
            backup_vm "$config_file" "$target_vm" "offline"
        else
            # Fazer apenas o tipo de backup especificado
            backup_vm "$config_file" "$target_vm" "$backup_type"
        fi
    else
        # Processar todas as VMs habilitadas
        local vms=$(yq eval '.vms[] | select(.enabled == true) | .name' "$config_file")
        
        if [ -z "$vms" ]; then
            echo "Nenhuma VM habilitada encontrada na configuração"
            return 0
        fi
        
        # Para cada VM habilitada, fazer o backup do tipo especificado
        for vm in $vms; do
            if [ "$backup_type" = "all" ]; then
                # Fazer ambos os tipos de backup
                backup_vm "$config_file" "$vm" "checkpoint"
                backup_vm "$config_file" "$vm" "offline"
            else
                # Fazer apenas o tipo de backup especificado
                backup_vm "$config_file" "$vm" "$backup_type"
            fi
        done
    fi
    
    return 0
}

# Executar backups conforme os parâmetros especificados
echo "====== INICIANDO GERENCIADOR DE BACKUPS DE VMs ======"
echo "Arquivo de configuração: $CONFIG_FILE"
echo "Tipo de backup: $BACKUP_TYPE"
echo "VM alvo: $TARGET_VM"

process_all_backups "$CONFIG_FILE" "$BACKUP_TYPE" "$TARGET_VM"
result=$?

echo "====== GERENCIADOR DE BACKUPS DE VMs CONCLUÍDO ======"
exit $result
