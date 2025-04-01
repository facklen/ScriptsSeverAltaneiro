#!/usr/bin/env python
# -*- coding: latin1 -*-
'''
Esta classe permite executar comandos num host remoto e fornece 
a entrada (ex: uma senha para o sudo) se necessário.
 
  Desenvolvido por: Diogenes Reis
  Email: diofolken@gmail.com
  Data de criação: 29/08/2016
  Última modificação: 19/01/2017
  Versão: 1.0
'''
import paramiko
import logging
import socket
import time
import datetime
import re

# Habilitar a linha a seguir caso seja necessário debugar a conexão feita pelo paramiko
#paramiko.common.logging.basicConfig(level=paramiko.common.DEBUG)
 
 
# ================================================================
# class MySSH
# ================================================================
class MySSH:
    '''
    Cria uma conexão SSH para um servidor e executa comandos.
    Uso típico:
 
        ssh = MySSH()
        ssh.connect('host', 'user', 'password', port=22)
        if ssh.connected() is False:
            sys.exit('Connection failed')
 
        # Executa um comando que não requer entrada.
        status, output = ssh.run('uname -a')
        print 'status = %d' % (status)
        print 'output (%d):' % (len(output))
        print '%s' % (output)
 
        # Executa um comando que requer uma entrada.
        status, output = ssh.run('sudo uname -a', 'sudo-password')
        print 'status = %d' % (status)
        print 'output (%d):' % (len(output))
        print '%s' % (output)
    '''
    def __init__(self, compress=True, verbose=False):
        '''
        Configuração inicial do nível de verbosidade e logger.
 
        @param compress  - Habilita/desabilita compressão.
        @param verbose   - Habilita/desabilita mensagens verbose.
        '''
        self.ssh = None
        self.transport = None
        self.compress = compress
        self.bufsize = 99999999
 
        # Conecta o logger ao módulo raiz (script que chama a classe)
        self.logger = logging.getLogger('root')
        # Define métodos para chamada do logger
        self.info = self.logger.info
        self.debug = self.logger.debug
        self.error = self.logger.error

 
    def __del__(self):
        if self.transport is not None:
            self.transport.close()
            self.transport = None


    def closeCon(self):
        if self.transport is not None:
            self.transport.close()
            self.transport = None

 
    def connect(self, hostname, username, password, keyfilename=None, port=22, timeout=10):
        '''
        Conecta a um host.
 
        @param hostname   -  endereço do host.
        @param username   -  username.
        @param password   -  senha.
        @param port       -  porta de conexão (padrão=22).
 
        @returns True if the connection succeeded or false otherwise.
        '''
        self.debug('conectando %s@%s:%d' % (username, hostname, port))
        self.hostname = hostname
        self.username = username
        self.port = port
        self.ssh = paramiko.SSHClient()
        self.ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            self.ssh.connect(hostname=hostname,
                             port=port,
                             username=username,
                             password=password,
                             key_filename=keyfilename,
                             timeout=timeout)
            self.transport = self.ssh.get_transport()
            self.transport.use_compression(self.compress)
            self.debug('bem-sucedido: %s@%s:%d' % (username,
                                               hostname,
                                               port))
        except socket.error as e:
            self.transport = None
            self.error('falha no socket: %s@%s:%d: %s' % (username,
                                                hostname,
                                                port,
                                                str(e)))
        except paramiko.BadAuthenticationType as e:
            self.transport = None
            self.error('falha na autenticação: %s@%s:%d: %s' % (username,
                                                hostname,
                                                port,
                                                str(e)))
 
        return self.transport is not None

 
    def run(self, cmd, input_data=None, timeout=10):
        '''
        Executa um comando com entrada de dados opcional.
 
        Aqui um exemplo que mostra como executar comandos sem entrada:
 
            ssh = MySSH()
            ssh.connect('host', 'user', 'password')
            status, output = ssh.run('uname -a')
            status, output = ssh.run('uptime')
 
        Aqui um exemplo que mostra como executar comandos que requerem entrada:
 
            ssh = MySSH()
            ssh.connect('host', 'user', 'password')
            status, output = ssh.run('sudo uname -a', '<sudo-password>')
 
        @param cmd         -  comando para executar.
        @param input_data  -  dados de entrada (padrão é None).
        @param timeout     -  timeout em segundos (padrão é 10 seconds).
        @returns (status, output) - retorna o status e a saída da execução do comando (stdout e stderr combinados).
        '''
        self.debug('executando comando: (%d) %s' % (timeout, cmd))

        if self.transport is None:
            self.error('Nenhuma conexão para %s@%s:%s' % (str(self.username),
                                                     str(self.hostname),
                                                     str(self.port)))
            return -1, 'ERRO: conexão não estabelecida \n'
 
        # Conserta o dado de entrada.
        input_data = self._run_fix_input_data(input_data)
 
        # Inicializa a sessão.
        self.debug('inicializando a sessão')
        session = self.transport.open_session()
        session.set_combine_stderr(True)
        session.get_pty()
        session.exec_command(cmd)
        output = self._run_poll(session, timeout, input_data)
        status = session.recv_exit_status()
        self.debug('tamanho da saída %d' % (len(output)))
        self.debug('status %d' % (status))
        return status, output
 

    def connected(self):
        '''
        Estou conectado no host?
 
        @returns True se connectado ou False caso contrário.
        '''
        return self.transport is not None

 
    def _run_fix_input_data(self, input_data):
        '''
        Conserta a entrada de dados fornecida pelo usuário para o comando.
 
        @param input_data   -  os dados de entrada (padrão é None).
        @returns input_data -  input_data consertada.
        '''
        if input_data is not None:
            if len(input_data) > 0:
                if '\\n' in input_data:
                    # Converte \n da entrada em novas linhas.
                    lines = input_data.split('\\n')
                    input_data = '\n'.join(lines)
            return input_data.split('\n')
        return []

    ''' 
    def _run_send_input(self, session, stdin, input_data):

        Envia um dado de entrada.
 
        @param session     - a sessão.
        @param stdin       - o stream stdin para a sessão.
        @param input_data  - o dado de entrada (padrão é None).

        if input_data is not None:
            self.debug('session.exit_status_ready() %s' % str(session.exit_status_ready()))
            self.debug('stdin.channel.closed %s' % str(stdin.channel.closed))
            if stdin.channel.closed is False:
                self.debug('enviando dado de entrada')
                stdin.write(input_data)
    '''
 
    def _run_poll(self, session, timeout, input_data):
        '''
        Apura saida até ao fim da execução do comando.
 
        @param session     -  a sessão.
        @param timeout     -  o timeout em segundos.
        @param input_data  -  o dado de entrada.
        @returns output    -  a saída
        '''
        interval = 0.1
        maxseconds = timeout
        maxcount = maxseconds / interval
 
        # Polling até completar o comando ou timeout
        # Note que não podemos usar o descritor de arquivo stout diretamente
        # porque é lido a cada 64K bytes (65536).
        input_idx = 0
        prompt = '[\d\D]+[#|>] ?$'
        timeout_flag = False
        self.debug('polling (%d, %d)' % (maxseconds, maxcount))
        start = datetime.datetime.now()
        start_secs = time.mktime(start.timetuple())
        output = ''
        session.setblocking(0)
        while True:
            got_chunk = False
            if session.recv_ready():
                data = session.recv(self.bufsize)
                output += data
                got_chunk = True
                self.debug('lendo %d bytes, total %d' % (len(data), len(output)))

                if input_idx > 0 and re.match(prompt,data):
                    session.close()
                    self.debug('prompt enoontrado')
                    break
 
                if session.send_ready():
                    if input_idx < len(input_data):
                        data = input_data[input_idx] + '\n'
                        input_idx += 1
                        self.debug('enviando dado de entrada %d' % (len(data)))
                        session.send(data)
 
            self.debug('session.exit_status_ready() = %s' % (str(session.exit_status_ready())))
            if not got_chunk and session.exit_status_ready() and not session.recv_ready():   
                break
 
            # Verificação de Timeout 
            now = datetime.datetime.now()
            now_secs = time.mktime(now.timetuple()) 
            et_secs = now_secs - start_secs
            self.debug('verificação de %d %d' % (et_secs, maxseconds))
            if et_secs > maxseconds:
                self.debug('polling finalizado - timeout')
                timeout_flag = True
                break
            time.sleep(0.200)
 
        self.debug('loop polling finalizado')
        if session.recv_ready():
            data = session.recv(self.bufsize)
            output += data
            self.debug('lendo %d bytes, total %d' % (len(data), len(output)))
 
        self.debug('polling finalizado - %d bytes de saída' % (len(output)))
        if timeout_flag:
            self.debug('adicionado mensagem de timeout')
            self.debug('ERRO: timeout após %d segundos' % (timeout))
            output += '\nERRO: timeout após %d segundos\n' % (timeout)
            session.close()
 
        return output


    def run_cmd(self, cmd, indata=None, timeout=10):
        '''
        Executa o comando com entrada opcional.
    
        @param cmd        -  o comando a ser executado.
        @param indata     -  o dado de entrada (opcional, padrão é None).
        @returns output   -  a saída do comando (stdout and stderr are combined).
        '''
        print '-' * 64
        print 'comando: %s' % (cmd)
        status, output = self.run(cmd, indata, timeout)
        self.debug('status: %d ' % (status))
        self.debug('saída : %d bytes' % (len(output)))
        print '-' * 64
        self.debug('\n%s' % (output))
        return output
 
