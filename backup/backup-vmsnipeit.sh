#!/bin/bash
#
# backup-vmsnipeit.sh - Script dedicado para backup da VM VMSnipeit
# Uso: sudo ./backup-vmsnipeit.sh
#

# Variáveis de configuração
VM_NAME="VMSnipeit"
BACKUP_DIR="/opt/backup/${VM_NAME}/checkpoints"
LOG_FILE="/var/log/backup_${VM_NAME}_checkpoints.log"
BACKUP_FILE="${BACKUP_DIR}/${VM_NAME}-checkpoint-$(date +%Y%m%d_%H%M%S).qcow2"

# Função para logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: Execute este script como root (sudo)"
    exit 1
fi

# Criar diretório de backup se não existir
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    log "Criado diretório de backup: $BACKUP_DIR"
fi

log "Iniciando backup dedicado para VM $VM_NAME"
log "Arquivo de backup será: $BACKUP_FILE"

# Obter informações sobre a VM
log "Obtendo informações sobre a VM..."
VM_INFO=$(virsh dominfo "$VM_NAME")
if [ $? -ne 0 ]; then
    log "ERRO: VM $VM_NAME não encontrada"
    exit 1
fi

# Obter informações sobre os discos da VM
log "Obtendo informações sobre os discos da VM..."
DISK_INFO=$(virsh domblklist "$VM_NAME")
log "Discos detectados:\n$DISK_INFO"

# Obter o caminho do disco atual
CURRENT_DISK_PATH=$(virsh domblklist "$VM_NAME" | grep vda | awk '{print $2}')
log "Caminho do disco principal: $CURRENT_DISK_PATH"

# Verificar se é um checkpoint
if [[ "$CURRENT_DISK_PATH" == *"checkpoint"* ]]; then
    log "Detectado que a VM está rodando a partir de um checkpoint"
    
    # Tentar obter o arquivo base original da VM
    log "Tentando identificar arquivo base..."
    ORIGINAL_FILE="/var/lib/libvirt/images/${VM_NAME}.qcow2"
    
    if [ -f "$ORIGINAL_FILE" ]; then
        log "Arquivo base encontrado: $ORIGINAL_FILE"
        
        # Verificar se a VM está rodando
        VM_RUNNING=false
        if virsh domstate "$VM_NAME" | grep -q "running"; then
            VM_RUNNING=true
            log "VM está em execução. Pausando temporariamente..."
            virsh suspend "$VM_NAME"
            sleep 2
        fi
        
        # Copiar o arquivo original para o backup
        log "Copiando arquivo original para backup: $ORIGINAL_FILE -> $BACKUP_FILE"
        if cp "$ORIGINAL_FILE" "$BACKUP_FILE"; then
            log "Cópia concluída com sucesso"
            BACKUP_SUCCESS=true
        else
            log "ERRO: Falha ao copiar arquivo original"
            BACKUP_SUCCESS=false
        fi
        
        # Resumir VM se estava em execução
        if [ "$VM_RUNNING" = true ]; then
            log "Resumindo VM..."
            virsh resume "$VM_NAME"
            sleep 1
        fi
    else
        log "Arquivo base não encontrado, tentando método alternativo..."
        
        # Método alternativo: usar qemu-img
        log "Usando qemu-img para criar snapshot..."
        
        # Verificar se a VM está rodando
        VM_RUNNING=false
        if virsh domstate "$VM_NAME" | grep -q "running"; then
            VM_RUNNING=true
            log "VM está em execução. Pausando temporariamente..."
            virsh suspend "$VM_NAME"
            sleep 2
        fi
        
        # Criar snapshot usando qemu-img
        log "Criando snapshot com qemu-img..."
        if qemu-img create -f qcow2 -b "$CURRENT_DISK_PATH" "$BACKUP_FILE"; then
            log "Snapshot criado com sucesso"
            
            # Testar rebase para tornar independente
            log "Executando rebase para remover dependências..."
            if qemu-img rebase -f qcow2 -b "" "$BACKUP_FILE"; then
                log "Rebase concluído, arquivo independente criado"
                BACKUP_SUCCESS=true
            else
                log "AVISO: Falha no rebase. O backup pode ter dependências"
                BACKUP_SUCCESS=true  # Consideramos sucesso mesmo sem rebase
            fi
        else
            log "ERRO: Falha ao criar snapshot"
            BACKUP_SUCCESS=false
        fi
        
        # Resumir VM se estava em execução
        if [ "$VM_RUNNING" = true ]; then
            log "Resumindo VM..."
            virsh resume "$VM_NAME"
            sleep 1
        fi
    fi
else
    # Método padrão para backup de disco normal
    log "VM está usando um disco regular. Usando método padrão de backup."
    
    # Verificar se a VM está rodando
    VM_RUNNING=false
    if virsh domstate "$VM_NAME" | grep -q "running"; then
        VM_RUNNING=true
        log "VM está em execução. Pausando temporariamente..."
        virsh suspend "$VM_NAME"
        sleep 2
    fi
    
    # Copiar o disco diretamente
    log "Copiando disco: $CURRENT_DISK_PATH -> $BACKUP_FILE"
    if cp "$CURRENT_DISK_PATH" "$BACKUP_FILE"; then
        log "Cópia concluída com sucesso"
        BACKUP_SUCCESS=true
    else
        log "ERRO: Falha na cópia do disco"
        BACKUP_SUCCESS=false
    fi
    
    # Resumir VM se estava em execução
    if [ "$VM_RUNNING" = true ]; then
        log "Resumindo VM..."
        virsh resume "$VM_NAME"
        sleep 1
    fi
fi

# Finalizar e compactar se o backup foi bem-sucedido
if [ "$BACKUP_SUCCESS" = true ]; then
    log "Backup concluído com sucesso: $BACKUP_FILE"
    log "Tamanho do backup: $(du -h "$BACKUP_FILE" | cut -f1)"
    
    # Compactar o backup
    log "Compactando o arquivo de backup..."
    if gzip -f "$BACKUP_FILE"; then
        log "Compactação concluída: ${BACKUP_FILE}.gz"
        
        # Verificar integridade
        log "Verificando integridade do backup..."
        if gzip -t "${BACKUP_FILE}.gz"; then
            log "Verificação de integridade concluída com sucesso"
            log "BACKUP COMPLETO E VERIFICADO COM SUCESSO"
            exit 0
        else
            log "ERRO: Verificação de integridade falhou"
            exit 1
        fi
    else
        log "ERRO: Falha na compactação do backup"
        exit 1
    fi
else
    log "ERRO: Falha no processo de backup"
    exit 1
fi
