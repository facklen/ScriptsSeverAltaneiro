#!/usr/bin/env python
# -*- coding: latin1 -*-
'''
Esta classe permite executar comandos num BD POSTGRESQL. 
 
  Desenvolvido por: Diogenes Reis
  Email: diofolken@gmail.com
  Data de criação: 30/07/2018
  Última modificação: 30/07/2018
  Versão: 1.0
'''
import psycopg2
import logging
import time
import datetime
import re

 
# ================================================================
# class ConnectPostgres
# ================================================================
class ConnectPostgres:
    '''
    Cria uma conexão a um DB Postgresql e executa comandos.
    Uso típico:
 
        con = ConnectPostgres(mhost, db, usr, pwd)
        sql = "insert into cidade values (default,'Rio de Janeiro','RJ')"
        if con.manipulatedb(sql):
           print('inserido com sucesso!')
        print (con.nextPK('cidade', 'id'))
        rs=con.consultdb("select * from cidade")
        for linha in rs:
           print (linha)
        con.closedb()
    '''

    _db=None

    def __init__(self, mhost, db, usr, pwd): 
        '''
        Conexão ao DB e configuração do logger.

        '''
        self._db = psycopg2.connect(host=mhost, database=db, user=usr,  password=pwd)
        # Conecta o logger ao módulo raiz (script que chama a classe)
        self.logger = logging.getLogger('root')
        # Define métodos para chamada do logger
        self.info = self.logger.info
        self.debug = self.logger.debug
        self.error = self.logger.error

    def __del__(self):
        self._db.close()

    def closedb(self):
        self._db.close()

    def manipulatedb(self, sql):
        self.debug('Executando comando\n%s' % (sql))
        try:
            cur=self._db.cursor()
            cur.execute(sql)
            cur.close();
            self._db.commit()
        except psycopg2.Error as e:
          self._db.rollback()
          self.debug('Falha na execução!')
          self.debug(e.pgerror)
          return False;
        self.debug('Sucesso na execução!')
        return True;

    def consultdb(self, sql):
        rs=None
        self.debug('Executando comando\n%s' % (sql))
        try:
            cur=self._db.cursor()
            cur.execute(sql)
            rs=cur.fetchall();
        except psycopg2.Error as e:
            self.debug('Falha na execução!')
            self.debug(e.pgerror)
            return None
        self.debug('Sucesso na execução!')
        return rs

    def nextPK(self, table, key):
        sql='select max('+key+') from '+table
        rs = self.consultdb(sql)
        pk = rs[0][0]  
        return pk+1 

    def getPK(self, table, key, namefield, name):
        sql="select "+key+" from "+table+" where "+namefield+" like '"+name+"'"
        rs = self.consultdb(sql)
        pk = None if not rs else rs[0][0] 
        return pk

