#!/usr/bin/env python
# -*- coding: latin1 -*-

'''
  send_mail.py - script para envio de emails

  Desenvolvido por: Diogenes Reis
  Email: diofolken@gmail.com
  Data de criação: 29/12/2017
  Última modificação: 03/01/2018

'''

import logging
import smtplib
from os.path import basename
from email.mime.application import MIMEApplication
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.header import Header
from email.utils import COMMASPACE, formatdate

# Conecta o logger ao módulo raiz (script que chama a classe)
logger = logging.getLogger('root')

def send_mail(send_to, subject, text, files=None,send_from='projimp@skybandalarga.com.br', passwd='1ecJK5A5ej',
              server='mail.skybandalarga.com.br'):
    assert isinstance(send_to, list)

    msg = MIMEMultipart()
    msg['From'] = send_from
    msg['To'] = COMMASPACE.join(send_to)
    msg['Date'] = formatdate(localtime=True)
    msg['Subject'] = Header(subject, 'utf-8')

    logger.info('Enviando email - De: %s' %(msg['From']))
    logger.info('Enviando email - Para: %s' %(msg['To']))
    logger.info('Enviando email - Assunto: %s' %(msg['To']))

    msg.attach(MIMEText(text,'plain','utf-8'))
  
    for f in files or []:
        logger.info('Enviando email - Arquivo anexado: %s' %(f))
        with open(f, "rb") as fil:
            part = MIMEApplication(
                fil.read(),
                Name=basename(f)
            )
        # After the file is closed
        part['Content-Disposition'] = 'attachment; filename="%s"' % basename(f)
        msg.attach(part)


    logger.debug('Enviando email - Servidor: %s' %(server))
    smtp = smtplib.SMTP(server)
    smtp.ehlo()
    logger.debug('Enviando email - Habilitação de TLS')
    smtp.starttls()
    logger.debug('Enviando email - Autenticação: %s/%s' %(send_from,passwd))
    smtp.login(send_from, passwd)
    smtp.sendmail(send_from, send_to, msg.as_string())
    logger.debug('Email enviado!')
    smtp.close()
