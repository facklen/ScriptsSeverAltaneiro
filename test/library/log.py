#!/usr/bin/env python
# -*- coding: latin1 -*-

import logging 
from logging.handlers import RotatingFileHandler

'''
  log.py - script para criação de configuração de log.

  Desenvolvido por: Diogenes Reis
  Email: diofolken@gmail.com
  Data de criação: 23/01/2017
  Última modificação: 23/01/2017

'''

def set_level_logger(logger,level):
   # Configura o nível do log (padrão: INFO)
   if level == 'critical':
      logger.setLevel(logging.CRITICAL)
   elif level == 'error':
      logger.setLevel(logging.ERROR)
   elif level  == 'warning':
      logger.setLevel(logging.WARNING)
   elif level == 'debug':
      logger.setLevel(logging.DEBUG)
   else:
      logger.setLevel(logging.INFO)
   return logger


def setup_custom_logger(name,filelog,level):
   '''
      setup_custom_logger - função para criar log customizado.
        Versão: 1.0
        Adicionado em: 23/01/2017 (Diogenes)

        @param name        - nome do logger.
        @param filelog     - arquivo de log.
        @param level       - nível do log.
   '''
   # Define o formato do log
   fmt = '%(levelname)s %(asctime)s %(name)s:%(module)s:%(funcName)s:%(lineno)d: %(message)s'
   format = logging.Formatter(fmt)
   # Define o log em arquivo rotativo
   handler = logging.handlers.RotatingFileHandler(filelog, mode='a', maxBytes=10000000, backupCount=5)
   # Aplica o formato do log ao handler
   handler.setFormatter(format)

   # Cria o logger
   logger = logging.getLogger(name)

   # Configura o nivel do log
   logger = set_level_logger(logger,level)

   # Adiciona o handler ao logger
   logger.addHandler(handler)

   # Retorna o logger 
   return logger
