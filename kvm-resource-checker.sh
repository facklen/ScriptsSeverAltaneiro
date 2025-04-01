#!/bin/bash

# Script para verificar recursos de VMs KVM e consolidação total
# Uso: ./kvm_resource_check.sh

# Cores para saída
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Verificar se virsh está instalado
if ! command -v virsh &> /dev/null; then
    echo -e "${RED}Erro: virsh não encontrado. Por favor, instale o pacote libvirt-clients.${NC}"
    exit 1
fi

# Verificar se o usuário tem permissão para executar virsh
if ! virsh list --all &> /dev/null; then
    echo -e "${RED}Erro: Sem permissão para executar o comando virsh. Execute como root ou adicione seu usuário ao grupo libvirt.${NC}"
    exit 1
fi

# Cabeçalho
echo -e "${YELLOW}===============================================${NC}"
echo -e "${YELLOW}      RELATÓRIO DE RECURSOS KVM              ${NC}"
echo -e "${YELLOW}===============================================${NC}"

# Inicializar contadores
total_vcpus=0
total_mem_gb=0
total_disk_gb=0

# Obter lista de todas as VMs
vms=$(virsh list --all --name)

if [ -z "$vms" ]; then
    echo -e "${RED}Nenhuma VM encontrada no servidor.${NC}"
    exit 0
fi

# Criar arquivo temporário para relatório
temp_file=$(mktemp)
echo -e "NOME VM\tSTATUS\tVCPUs\tMEMÓRIA (GB)\tDISCO (GB)" > "$temp_file"

# Para cada VM, coletar informações
for vm in $vms; do
    # Verificar se a VM existe
    if ! virsh dominfo "$vm" &> /dev/null; then
        continue
    fi
    
    # Obter status da VM
    status=$(virsh domstate "$vm" 2>/dev/null)
    
    # Obter número de vCPUs
    vcpus=$(virsh dominfo "$vm" 2>/dev/null | grep "CPU(s)" | awk '{print $2}')
    
    # Obter memória em KB e converter para GB
    mem_kb=$(virsh dominfo "$vm" 2>/dev/null | grep "Max memory" | awk '{print $3}')
    mem_gb=$(awk "BEGIN {printf \"%.2f\", $mem_kb/1024/1024}")
    
    # Inicializar tamanho total do disco
    disk_gb=0
    
    # Obter discos associados à VM
    disks=$(virsh domblklist "$vm" 2>/dev/null | grep -v "^$\|Target\|------" | awk '{print $2}')
    
    # Para cada disco, obter o tamanho
    for disk in $disks; do
        # Ignorar quando o source está vazio ou é um dispositivo de CD-ROM
        if [ -z "$disk" ] || [ "$disk" = "-" ]; then
            continue
        fi
        
        # Verificar se é um caminho de arquivo ou um dispositivo de bloco
        if [ -f "$disk" ]; then
            # É um arquivo de imagem
            disk_size=$(qemu-img info "$disk" 2>/dev/null | grep "virtual size" | awk '{print $3}' | tr -d '(')
            
            # Se qemu-img falhar, tente obter o tamanho do arquivo
            if [ -z "$disk_size" ]; then
                disk_size=$(du -b "$disk" 2>/dev/null | awk '{print $1}')
                disk_size_gb=$(awk "BEGIN {printf \"%.2f\", $disk_size/1024/1024/1024}")
            else
                # Converter para GB se não estiver em GB
                if [[ "$disk_size" == *"GiB"* ]]; then
                    disk_size_gb=${disk_size//GiB/}
                elif [[ "$disk_size" == *"TiB"* ]]; then
                    tb=${disk_size//TiB/}
                    disk_size_gb=$(awk "BEGIN {printf \"%.2f\", $tb*1024}")
                elif [[ "$disk_size" == *"MiB"* ]]; then
                    mb=${disk_size//MiB/}
                    disk_size_gb=$(awk "BEGIN {printf \"%.2f\", $mb/1024}")
                else
                    # Assumir bytes se não houver unidade
                    disk_size_gb=$(awk "BEGIN {printf \"%.2f\", $disk_size/1024/1024/1024}")
                fi
            fi
        elif [ -b "$disk" ]; then
            # É um dispositivo de bloco
            disk_size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null)
            if [ -z "$disk_size_bytes" ]; then
                disk_size_gb=0
            else
                disk_size_gb=$(awk "BEGIN {printf \"%.2f\", $disk_size_bytes/1024/1024/1024}")
            fi
        else
            # Não foi possível determinar o tamanho
            disk_size_gb=0
        fi
        
        # Adicionar ao total
        disk_gb=$(awk "BEGIN {printf \"%.2f\", $disk_gb + $disk_size_gb}")
    done
    
    # Adicionar aos totais gerais
    total_vcpus=$((total_vcpus + vcpus))
    total_mem_gb=$(awk "BEGIN {printf \"%.2f\", $total_mem_gb + $mem_gb}")
    total_disk_gb=$(awk "BEGIN {printf \"%.2f\", $total_disk_gb + $disk_gb}")
    
    # Adicionar linha ao relatório
    echo -e "$vm\t$status\t$vcpus\t$mem_gb\t$disk_gb" >> "$temp_file"
done

# Exibir relatório em formato de tabela
echo -e "${GREEN}Lista de VMs e seus recursos:${NC}"
column -t -s $'\t' "$temp_file"
rm "$temp_file"

# Exibir recursos do host
echo -e "\n${BLUE}Recursos do Host:${NC}"
host_cpus=$(grep -c ^processor /proc/cpuinfo)
host_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
host_mem_gb=$(awk "BEGIN {printf \"%.2f\", $host_mem_kb/1024/1024}")

echo -e "CPUs Físicas: $host_cpus"
echo -e "Memória Total: $host_mem_gb GB"

# Exibir consolidação
echo -e "\n${YELLOW}Consolidação de Recursos:${NC}"
echo -e "Total de vCPUs alocadas: $total_vcpus"
echo -e "Total de Memória alocada: $total_mem_gb GB"
echo -e "Total de Disco alocado: $total_disk_gb GB"

# Calcular taxas de consolidação
cpu_ratio=$(awk "BEGIN {printf \"%.2f\", $total_vcpus/$host_cpus}")
mem_ratio=$(awk "BEGIN {printf \"%.2f\", $total_mem_gb/$host_mem_gb}")

echo -e "Taxa de consolidação de CPU (vCPU:pCPU): $cpu_ratio:1"
echo -e "Taxa de consolidação de Memória (VM:Host): $mem_ratio:1"

# Verificar sobre-alocação
if (( $(echo "$cpu_ratio > 1" | bc -l) )); then
    echo -e "${RED}Alerta: CPUs estão sobre-alocadas em $cpu_ratio vezes.${NC}"
else
    echo -e "${GREEN}Info: CPUs não estão sobre-alocadas.${NC}"
fi

if (( $(echo "$mem_ratio > 0.9" | bc -l) )); then
    echo -e "${RED}Alerta: Memória está com alta alocação ($mem_ratio da capacidade total).${NC}"
else
    echo -e "${GREEN}Info: Memória está dentro de limites seguros.${NC}"
fi

echo -e "${YELLOW}===============================================${NC}"
echo -e "${YELLOW}            FIM DO RELATÓRIO                ${NC}"
echo -e "${YELLOW}===============================================${NC}"
