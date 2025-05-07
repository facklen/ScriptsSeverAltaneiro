#!/bin/bash
# Script para diagnosticar configuração LVM de uma VM
# Uso: sudo ./lvm-diagnose.sh VM_NAME

if [ $# -lt 1 ]; then
    echo "Uso: $0 <nome_vm>"
    exit 1
fi

VM_NAME="$1"
echo "====== DIAGNÓSTICO DA VM $VM_NAME ======"

# Verificar se a VM existe
if ! virsh dominfo "$VM_NAME" &> /dev/null; then
    echo "ERRO: VM $VM_NAME não encontrada no libvirt"
    exit 1
fi

# Obter e salvar XML da VM
echo "XML da VM:"
virsh dumpxml "$VM_NAME" > /tmp/vm_xml.txt
head -50 /tmp/vm_xml.txt | grep -A20 "<disk"
echo "[...]"

# Verificar discos da VM
echo -e "\nDiscos da VM:"
virsh domblklist "$VM_NAME"

# Obter tipo de disco e caminho para o primeiro disco
DISK_NAME=$(virsh domblklist "$VM_NAME" | awk 'NR>2 && $2 != "-" {print $1; exit}')
echo -e "\nPrimeiro disco: $DISK_NAME"

# Extrair tipo e caminho do XML
DISK_TYPE=$(grep -A10 "<target dev=\"$DISK_NAME\"" /tmp/vm_xml.txt | grep -oP 'type="\K[^"]+' || echo "Não encontrado")
echo "Tipo de disco (pelo XML): $DISK_TYPE"

# Tentar várias formas de extrair o caminho do disco
echo -e "\nTentando diferentes métodos de extração de caminho:"

echo "1. Via source file:"
SOURCE_FILE=$(grep -A15 "<target dev=\"$DISK_NAME\"" /tmp/vm_xml.txt | grep -oP 'file="\K[^"]+' || echo "Não encontrado")
echo "   $SOURCE_FILE"

echo "2. Via source dev:"
SOURCE_DEV=$(grep -A15 "<target dev=\"$DISK_NAME\"" /tmp/vm_xml.txt | grep -oP 'dev="\K[^"]+' || echo "Não encontrado")
echo "   $SOURCE_DEV"

# Verificar se é LVM
if [[ "$SOURCE_DEV" == *"/dev/"* ]]; then
    echo -e "\nDISCO PARECE SER LVM!"
    echo "Verificando detalhes LVM:"
    
    # Tentar obter informações do volume LVM
    if command -v lvs &> /dev/null && [ -e "$SOURCE_DEV" ]; then
        echo "Informações do volume LVM:"
        lvs "$SOURCE_DEV" || echo "Não foi possível obter informações LVM"
        
        # Mostrar grupo e volume lógico
        VG_NAME=$(lvs --noheadings -o vg_name "$SOURCE_DEV" 2>/dev/null | tr -d ' ' || echo "Não encontrado")
        LV_NAME=$(lvs --noheadings -o lv_name "$SOURCE_DEV" 2>/dev/null | tr -d ' ' || echo "Não encontrado")
        echo "VG: $VG_NAME, LV: $LV_NAME"
    else
        echo "Comando LVS não disponível ou dispositivo não acessível: $SOURCE_DEV"
    fi
fi

# Verificar se os discos são acessíveis
echo -e "\nVerificando acesso aos discos:"
if [ -e "$SOURCE_FILE" ]; then
    echo "Arquivo $SOURCE_FILE existe e é acessível"
    stat "$SOURCE_FILE" | grep "Size\|Device"
elif [ -e "$SOURCE_DEV" ]; then
    echo "Dispositivo $SOURCE_DEV existe e é acessível"
    ls -la "$SOURCE_DEV"
else
    echo "Nenhum dos caminhos é acessível diretamente"
fi

# Mostrar estado da VM
echo -e "\nEstado atual da VM:"
virsh domstate "$VM_NAME"

# Limpar arquivo temporário
rm -f /tmp/vm_xml.txt

echo "====== DIAGNÓSTICO CONCLUÍDO ======"
