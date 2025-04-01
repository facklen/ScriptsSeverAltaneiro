#!/usr/bin/env python
# -*- coding: latin1 -*-

import logging 

'''
  common.py - script que serve como biblioteca para funções comuns que podem ser utilizadas entre vários scripts python.

  Desenvolvido por: Diogenes Reis
  Email: diofolken@gmail.com
  Data de criação: 29/08/2016
  Última modificação: 19/01/2017

'''

# Conecta o logger ao módulo raiz (script que chama a classe)
logger = logging.getLogger('root')

def getcred():
   '''
      getcred -  função para leitura de credenciais (login e senha) 
        Versão: 1.0
        Adicionado em: 29/08/2017 (Diogenes)
   '''
   import getpass
   USER=raw_input("Username: ")
   PASS=getpass.getpass()
   return (USER,PASS)


def read_file(file):
   '''
      read_file -  função para ler arquivo de configuração estilo .csv
        Versão: 1.0
        Adicionado em: 29/08/2017 (Diogenes)

        @param file - nome do arquivo de configuração
        @returns elements - retorna as linhas do arquivo
   '''
   elements=[]
   with open(file) as f:
      for line in f:
         li=line.strip()
         if not li.startswith("#"):
            elements.append(li)
   return elements


def ConfigSectionMap(Config,section):
   '''
      ConfigSectionMap -  função para mapear parâmetros de arquivo de configuração
        Versão: 1.0
        Adicionado em: 05/01/2017 (Diogenes)

        @param Config  - objeto com os dados do arquivo de configuração
        @param section - seção do arquivo de configuração
        @returns dict1 - retorna dicionário com os parâmetros lidos do arquivo de configuração

        Exemplo de arquivo de configuração:

        [VMME01BSA001]                                            # Nome da seção
        address: 10.61.112.65                                     # Parâmetro address
        port: 22                                                  # Parâmetro port
        command: show configuration | display set | nomore        # Parâmetro command
        type_cmd: 0                                               # Parâmetro type_cmd
        dir_backup: /var/dumps-affirmed/vmme01bsa001              # Parâmetro dir_backup
        retention_day: 90                                         # Parâmetro retention_day
   '''
   dict1 = {}
   options = Config.options(section)
   for option in options:
       try:
           dict1[option] = Config.get(section, option)
           if dict1[option] == -1:
               DebugPrint("skip: %s" % option)
               logger.debug('skip: %s' %(option))
       except:
           print("exception on %s!" % option)
           dict1[option] = None
   return dict1


def make_sure_path_exists(directory):
   '''
      make_sure_path_exists -  função para verificar se diretório existe. Se não existir, o diretório é criado
        Versão: 1.0
        Adicionado em: 19/01/2017 (Diogenes)

        @param directory - diretório para a verificação de existência
   '''
   import os
   if not os.path.exists(directory):
      logger.debug('Criando diretório %s' %(directory))
      os.makedirs(directory)
   else:
      logger.debug('Diretório %s já existe' %(directory))


def delete_old_files(directory,agefile): 
   '''
      delete_old_files - função para apagar arquivos antigos.
        Versão: 1.0
        Adicionado em: 19/01/2017 (Diogenes)

        @param directory - diretório para a verificação de arquivos antigos
        @param agefile   - número de dias que os arquivos serão retidos no servidor
   '''
   import datetime, os
   i = 0
   for dirpath, dirnames, filenames in os.walk(directory):
       for file in filenames:
          curpath = os.path.join(dirpath, file)
          file_modified = datetime.datetime.fromtimestamp(os.path.getmtime(curpath))
          if datetime.datetime.now() - file_modified > datetime.timedelta(days=agefile):
             os.remove(curpath)
             i += 1
   logger.debug('%d arquivos apagados' %(i))


def write_file(filename,data):
   '''
      write_file - função para escrita de arquivos
        Versão: 1.0
        Adicionado em: 19/01/2017 (Diogenes)

        @param filename - nome do arquivo de escrita
        @param data     - dados a serem escritos no arquivo
   '''
   with open(filename, "w") as outfile:
      outfile.write(data)
      outfile.flush()
      logger.debug('Arquivo %s salvo' %(filename))


def ftp_explicity_ssl_huawei(host,port,user,pswd,directory,timeout):
   '''
      ftp_explicity_ssl_huawei - função para acesso FTP explicito sobre SSL no MME Huawey
        Versão: 1.0
        Adicionado em: 15/12/2017 (Diogenes)

        @param host - endereço IP do servidor FTP 
        @param port - porta TCP
        @param user - usuário para acesso
        @param pswd - senha para acesso
        @param directory - diretório de armazenamento dos arquivos
        @param filename - padrão de nome de arquivo para download
   '''
   import ftplib, ssl

   ftps=ftplib.FTP_TLS()
   logger.debug('FTP sobre SSL instanciado')
   ctx = ssl.SSLContext(ssl.PROTOCOL_SSLv23)
   ctx.set_ciphers('HIGH:!DH:!aNULL')
   ftps = ftplib.FTP_TLS(context=ctx)
   logger.debug('Alterado cifra do contexto SSL para permitir chaves pequenas')
   ftps.connect(host,port,timeout=timeout)
   ftps.login(user,pswd)
   logger.debug('Conexão FTP efetuada!')
   ftps.prot_p()
   logger.debug('Ativado conexão segura de dados')
   ftps.cwd(directory)
   logger.debug('Acesso ao diretório: %s' %(directory))
   files = ftps.nlst()
   logger.debug('Arquivos listados:\n %s' %(files))
   filename = sorted(files)[-1]
   logger.debug('Arquivo mais recente: %s' %(filename))
   myfile = open(filename, 'wb')
   ftps.retrbinary('RETR %s' % filename, myfile.write)
   logger.debug('Arquivo baixado com sucesso')
   #ftps.delete(filename)
   ftps.close()
   return filename


def sftp_hosts(hostname=None,user=None,keyfilename=None,remotefile=None,localfile=None,passwd=None,port=22,removefile=0):
   '''
      ftp_hosts - função para acesso SFTP aos elementos de rede
        Versão: 1.0
        Adicionado em: 08/01/2018 (Diogenes)

        @param host - endereço IP do servidor SFTP
        @param user - usuário para acesso
        @param keyfilename - arquivo para PKI
        @param passwd - senha para acesso
        @param port - porta TCP
        @param filename - nome de arquivo para download
   '''
   import pysftp

   logger.info('SFTP ao host %s' %(hostname))
   logger.debug('Parâmetro user: %s' %(user))
   logger.debug('Parâmetro keyfilename: %s' %(keyfilename))
   logger.debug('Parâmetro remotefile: %s' %(remotefile))
   logger.debug('Parâmetro localfile: %s' %(localfile))
   logger.debug('Parâmetro removefile: %s' %(removefile))
   if keyfilename:
      logger.debug('Acesso via certificado')
      with pysftp.Connection(hostname, username=user, private_key=keyfilename) as sftp:
          sftp.get(remotefile,localfile)         # get a remote file
          logger.debug('Arquivo coletado: %s' %(localfile))
          if int(removefile):
             sftp.remove(remotefile)               # remove a remote file
             logger.debug('Arquivo removido: %s' %(remotefile))
   elif passwd:
      logger.debug('Acesso via senha')
      with pysftp.Connection(hostname, username=user, password=passwd) as sftp:
          sftp.get(remotefile,localfile)         # get a remote file
          logger.debug('Arquivo coletado: %s' %(localfile))
          if int(removefile):
             sftp.remove(remotefile)               # remove a remote file
             logger.debug('Arquivo removido: %s' %(remotefile))

def Ftraffic(value,pattern):
   '''
      Ftraffic - função para conversão de tráfego
        Versão: 1.0
        Adicionado em: 08/01/2018 (Diogenes)

        @param value - valor do tráfego em bps
        @param pattern - padrão a ser convertido:
                G - Gbps
                M - Mbps
                K - Kbps
        @returns - valor convertido
   '''
   if pattern == 'G':
      return value / (10**9)
   elif pattern == 'M':
      return value / (10**6)
   elif pattern == 'K':
      return value / (10**3)
