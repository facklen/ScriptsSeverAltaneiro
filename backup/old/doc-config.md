## Estrutura do Arquivo de Configuração YAML

O arquivo `vm_backup_config.yaml` está organizado em três seções principais:

1. **Configurações Globais**
2. **Parâmetros de Retenção Padrão**
3. **Lista de VMs**

Vamos examinar cada seção e seus campos:

### 1. Configurações Globais (`global`)

```yaml
global:
  backup_base_dir: /opt/backup
  log_dir: /var/log
  notification:
    enabled: true
    method: email
    email:
      recipient: admin@example.com
```

- **`backup_base_dir`**: Diretório base onde todos os backups serão armazenados. O sistema criará subdiretórios para cada VM dentro desta pasta.
  
- **`log_dir`**: Diretório onde os arquivos de log serão criados. Os logs são nomeados como `backup_NOME-VM_TIPO.log`.

- **`notification`**: Configurações para o sistema de notificação
  - **`enabled`**: `true` para ativar notificações, `false` para desativar
  - **`method`**: Método de notificação a ser usado (`email`, `slack`, `teams`, ou `none`)
  - **`email`**: Configurações específicas para notificações por email
    - **`recipient`**: Endereço de email para receber notificações

### 2. Parâmetros de Retenção Padrão (`default_retention`)

```yaml
default_retention:
  checkpoint: 7  # dias para manter checkpoints
  weekly: 8      # número de backups semanais a manter
```

- **`checkpoint`**: Número de dias para manter backups incrementais (checkpoints). Arquivos mais antigos que este valor serão automaticamente excluídos.

- **`weekly`**: Número de backups semanais completos (offline) a manter. O sistema manterá os N backups mais recentes e excluirá os mais antigos.

### 3. Lista de VMs (`vms`)

```yaml
vms:
  - name: winserver2022
    enabled: true
    description: "Windows Server 2022 com Active Directory"
    vm_file: /var/lib/libvirt/images/win2022.qcow2
    backup_types:
      - type: checkpoint
        enabled: true
        schedule: "daily"
        retention_days: 7
        special_options:
          keep_ram: true
      - type: offline
        enabled: true
        schedule: "weekly"
        retention_count: 8
        shutdown_timeout: 600
        special_options:
          keep_last_checkpoint: false
```

- **`name`**: Nome da VM no sistema libvirt. Este deve ser exatamente igual ao nome usado nos comandos `virsh`.

- **`enabled`**: Se `true`, esta VM será incluída nos backups; se `false`, será ignorada.

- **`description`**: Descrição textual da VM (apenas para referência humana).

- **`vm_file`**: Caminho completo para o arquivo da imagem de disco principal da VM.

- **`backup_types`**: Lista de tipos de backup a serem realizados para esta VM
  
  - Para cada tipo de backup:
    - **`type`**: Tipo de backup (`checkpoint` ou `offline`)
    - **`enabled`**: Se este tipo específico de backup está ativado para esta VM
    - **`schedule`**: Valor de referência para agendar no crontab (apenas para documentação)
    - **`retention_days`/`retention_count`**: Sobrescreve os valores padrão de retenção para esta VM específica

  - Opções específicas para backup por checkpoint:
    - **`special_options.keep_ram`**: Se `true`, salva o estado da RAM no checkpoint (útil para VMs que exigem consistência de memória)

  - Opções específicas para backup offline:
    - **`shutdown_timeout`**: Tempo máximo (em segundos) para aguardar o desligamento normal da VM antes de forçar
    - **`special_options.keep_last_checkpoint`**: Se `true`, mantém o checkpoint mais recente após o backup offline

## Exemplo Completo Explicado

```yaml
# Configuração global - define configurações aplicáveis a todas as VMs
global:
  backup_base_dir: /opt/backup   # Todos os backups serão armazenados aqui
  log_dir: /var/log              # Todos os logs serão armazenados aqui
  notification:
    enabled: true                # Ativa o sistema de notificações
    method: email                # Envia notificações por email
    email:
      recipient: admin@example.com  # Endereço para receber alertas

# Configurações de retenção padrão - aplicadas a todas as VMs, a menos que sobrescritas
default_retention:
  checkpoint: 7  # Mantém backups incrementais por 7 dias
  weekly: 8      # Mantém os 8 backups completos mais recentes

# Lista de VMs para backup - cada VM tem suas próprias configurações
vms:
  # Windows Server com AD
  - name: winserver2022          # Nome da VM no libvirt
    enabled: true                # Esta VM será incluída nos backups
    description: "Windows Server 2022 com Active Directory"  # Descrição informativa
    vm_file: /var/lib/libvirt/images/win2022.qcow2  # Caminho do arquivo de disco
    backup_types:
      # Backup incremental diário
      - type: checkpoint         # Tipo de backup: incremental usando snapshots
        enabled: true            # Este tipo de backup está ativado
        schedule: "daily"        # Referência para agendar (documentação)
        retention_days: 7        # Mantém por 7 dias (sobrescreve o padrão)
        special_options:
          keep_ram: true         # Inclui estado da RAM nos checkpoints

      # Backup completo semanal
      - type: offline            # Tipo de backup: desliga a VM e faz backup completo
        enabled: true            # Este tipo de backup está ativado
        schedule: "weekly"       # Referência para agendar (documentação)
        retention_count: 8       # Mantém 8 backups (sobrescreve o padrão)
        shutdown_timeout: 600    # 10 minutos para desligar normalmente
        special_options:
          keep_last_checkpoint: false  # Remove todos os checkpoints após backup

  # Exemplo de outra VM
  - name: ubuntu_server          # Nome da segunda VM
    enabled: true                # Esta VM será incluída nos backups
    description: "Ubuntu Server LTS"  # Descrição informativa
    vm_file: /var/lib/libvirt/images/ubuntu.qcow2  # Caminho do arquivo de disco
    backup_types:
      - type: checkpoint         # Backup incremental
        enabled: true            # Ativado
        schedule: "daily"        # Referência para agendar
      - type: offline            # Backup completo
        enabled: false           # Desativado - esta VM não terá backup offline
```

## Notas Importantes:

1. **Dependência do `yq`**: O sistema requer a ferramenta `yq` (YAML processor) para ler o arquivo de configuração. Você pode instalá-la com `sudo apt install yq` no Ubuntu.

2. **Caminhos Absolutos**: Recomendo usar caminhos absolutos para todos os arquivos e diretórios na configuração.

3. **Campos Opcionais vs. Obrigatórios**:
   - Campos obrigatórios: `name`, `enabled`, `vm_file` para cada VM
   - Campos opcionais: `description`, valores específicos de retenção, opções especiais

4. **Extensibilidade**: Você pode adicionar novos campos no futuro se precisar de mais opções, mantendo a compatibilidade com os scripts existentes.

5. **Valores Padrão**: O sistema usa valores padrão razoáveis se campos opcionais forem omitidos.

Você pode adicionar quantas VMs quiser à lista, cada uma com suas próprias configurações específicas, tornando o sistema extremamente flexível.