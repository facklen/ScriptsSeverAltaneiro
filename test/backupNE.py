#!/usr/bin/env python
# -*- coding: latin1 -*-
'''
  backupNE.py - Python Script para fazer backup de configuração de elementos de rede

  Desenvolvido por: Diogenes Reis
  Email: diofolken@gmail.com
  Data de criação: 29/08/2016
  Última modificação: 19/01/2017
  Versão: 1.0
'''
import sys, re, time
sys.path.append('/home/goku/scripts/library')
import ConfigParser
import logging 
import os
import log
from connect_ssh import MySSH
from commom import getcred, read_file, ConfigSectionMap, make_sure_path_exists, delete_old_files, write_file
from optparse import OptionParser


def main(argv):
   
   # Inicializa logging
   logpath = os.path.dirname(os.path.abspath(__file__)) + '/logs'
   make_sure_path_exists(logpath)
   logger = log.setup_custom_logger('root',logpath + '/backupNE.log','info')

   logger.info('#' * 64)
   logger.info('Inicializando Backup!')
   logger.info('#' * 64)

   # Leitura dos parâmetros de entrada
   logger.debug('Lendo parâmetros de entrada.')
   try:    # Coleta e verifica os parâmetros passados por linha de comando
      parser = OptionParser(usage='usage: %prog [options] arguments',version='%prog 1.0')
      parser.add_option("-c", "--cfile",  dest="configfile" , help="define o arquivo de configuracao")
      (options, args) = parser.parse_args()

      if not options.configfile:   # se não for passado o parâmetro de arquivo de configuração
         logger.error('Arquivo de configuração não definido!')
         parser.error('Arquivo de configuracao nao definido!')
         print parser.print_help()
         sys.exit(2)
   except Exception, e:
      logger.error('Há um erro no parser de leitura dos parâmetros de entrada', exc_info=True)
      sys.exit(2)
   logger.debug('Parâmetros de entrada lidos.')

   # Leitura do arquivo de configuração
   logger.debug('Lendo arquivo de configuração.')
   configpath = os.path.abspath(os.path.join(os.path.dirname(os.path.realpath(__file__)), os.pardir)) + '/config'
   Config = ConfigParser.ConfigParser()
   Config.read(configpath + '/' + options.configfile)
   logger.debug('Arquivo de configuração lido.')

   # Loop para execução de backup
   for host in Config.sections():
       logger.info('=' * 64)
       logger.info('Backup do NE %s' %(host))
       print
       print '=' * 64
       print "Backup do NE: " + host

       ''' 
         Verifica se o usuário é fornecido. 
	   - Se for fornecido, adota o usuário na conexão com chave pública.
           - Se não for fornecido, solicita as credenciais de usuário/senha.
       '''
       if not Config.has_option(host,'user'):
          (USER,PASS) = getcred()
          keyfilename = None
          logger.debug('Autenticacao com NE via credenciais manuais - Usuário: %s' %(USER))
       else:
          USER = ConfigSectionMap(Config,host)["user"]
          keyfilename = ConfigSectionMap(Config,host)["keyfilename"]
          PASS = None
          logger.debug('Autenticacao com NE via arquivo de chave pública - Arquivo: %s' %(keyfilename))

       ''' 
         Verifica o tipo de NE:
           - Tipo 0: NE que precisa que o comando seja enviado como entrada (ver detalhamento na classe MySSH).
           - Tipo 1: NE que o comando é executado normalmente.
       '''
       if not Config.has_option(host,'type_cmd'):
          type_cmd=1
       else:
          type_cmd=int(ConfigSectionMap(Config,host)["type_cmd"])
       logger.debug('NE com comando tipo %d ' %(type_cmd))

       ''' 
         Verifica o timeout do NE. Se não tiver tal parâmetro na seção do host, adota-se o padrão de 10 segs.
       '''
       if not Config.has_option(host,'timeout'):
          timeout=10
       else:
          timeout=int(ConfigSectionMap(Config,host)["timeout"])
       logger.debug('Timeout configurado para conexão %d ' %(timeout))

       # Cria a conexão SSH
       try:
          ssh = MySSH()
          ssh.connect(hostname=ConfigSectionMap(Config,host)["address"],
                      username=USER,
                      password=PASS,
                      port=int(ConfigSectionMap(Config,host)["port"]),
                      keyfilename=keyfilename,
                      timeout=timeout)
          if ssh.connected() is False:
              logger.error('ERROR: conexão não foi aberta.')
              continue
       except Exception, e:
          logger.error('Erro na conexão.', exc_info=True)
          continue

       # Executa o comando para coletar a configuração do NE.
       try:
          if type_cmd:
             output = ssh.run_cmd(ConfigSectionMap(Config,host)["command"],timeout=timeout)
          else:
             output = ssh.run_cmd(ConfigSectionMap(Config,host)["command"],indata=ConfigSectionMap(Config,host)["command"],timeout=timeout)
       except Exception, e:
          logger.error('Erro na execução do comando.', exc_info=True)
          continue
       finally:
          try:
             ssh.closeCon()
          except: pass

       # Verifica se o diretório existe. Caso não exista, cria o diretório.
       logger.debug('Verificando diretório para armazenamento de configuração')
       directory = ConfigSectionMap(Config,host)["dir_backup"] + '/' + host.lower()
       make_sure_path_exists(directory)

       # Salva configuração em arquivo
       logger.debug('Salvando arquivo de configuração')
       curtime = str(time.localtime()[0])+'-'+str(time.localtime()[1])+'-'+str(time.localtime()[2])+'-'+str(time.localtime()[3])+'h'+str(time.localtime()[4])+'m'
       filename = directory + '/' + host.lower() + '_' + curtime + '.cnf'
       write_file(filename,output)
       
       # Apaga arquivos antigos
       logger.debug('Apagando arquivo de configuração superiores a %d dias' %(int(ConfigSectionMap(Config,host)["retention_day"])))
       delete_old_files(ConfigSectionMap(Config,host)["dir_backup"],int(ConfigSectionMap(Config,host)["retention_day"]))
         
       logger.info('Execução de Backup do NE %s bem-sucedido' %(host))
       logger.info('=' * 64)
       print '=' * 64

   logger.info('#' * 64)
   logger.info('Fim de execução do script de Backup!')
   logger.info('#' * 64)
    


if __name__ == "__main__":
   main(sys.argv[1:])

sys.exit(0)


