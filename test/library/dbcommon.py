#!/usr/bin/env python
# -*- coding: latin1 -*-

import logging 

'''
  dbcommon.py - script que serve como biblioteca para funções comuns de banco de dados que podem ser utilizadas entre vários scripts python.

  Desenvolvido por: Diogenes Reis
  Email: diofolken@gmail.com
  Data de criação: 24/08/2018
  Última modificação: 

'''

# Conecta o logger ao módulo raiz (script que chama a classe)
logger = logging.getLogger('root')

def insertdbEPC(con,epc,ip=None,city=None):
   '''
      insertdbEPC - função para inserir um novo EPC na tabela EPC
        Versão: 1.0
        Adicionado em: 24/08/2017 (Diogenes)

        @param con - conexão com o banco de dados
        @param host - nome do EPC a ser inserido
        @param ip - endereço ip do EPC a ser inserido
        @param city - cidade do EPC a ser inserido
        @returns - FALSE ou TRUE
   '''
   epcid = con.getPK( 'epc', 'epc_id', 'epc_name', epc)
   if (epcid is None) and (city is not None) and (ip is None):
      logger.debug('EPC %s não encontrado no banco de dados. Iniciando inserção' %(epc))
      cityid = con.getPK( 'city', 'city_id', 'name', city)
      if cityid is None:
          cityid = 99999   # Cidade: Não Determinado
      sql = "insert into epc (epc_name, fk_city_cidade_id) values ('"+epc+"',"+str(cityid)+')'
      if con.manipulatedb(sql):
         logger.debug('EPC %s inserido' %(epc))
         return True
   elif (epcid is None) and (city is not None) and (ip is not None):
      logger.debug('EPC %s não encontrado no banco de dados. Iniciando inserção' %(epc))
      cityid = con.getPK( 'city', 'city_id', 'name', city)
      if cityid is None:
          cityid = 99999   # Cidade: Não Determinado
      sql = "insert into epc (epc_name, oam_ip, fk_city_cidade_id) values ('"+epc+"','"+ip+"',"+str(cityid)+')'
      if con.manipulatedb(sql):
         logger.debug('EPC %s inserido' %(epc))
         return True
   elif (epcid is None) and (city is None) and (ip is None):
      logger.debug('EPC %s não encontrado no banco de dados. Iniciando inserção' %(epc))
      sql = "insert into epc (epc_name) values ('"+epc+"')"
      if con.manipulatedb(sql):
         logger.debug('EPC %s inserido' %(epc))
         return True
   elif (epc is not None) and (ip is not None):
      logger.debug('EPC %s encontrado no banco de dados.' %(epc))
      logger.debug('Verificando registro do endereço IP...')
      oamip = con.consultdb("select oam_ip from epc where epc_name like '"+epc+"'")
      if (oamip[0][0] is None) or (not oamip[0][0]):
         logger.debug('Inserindo registro do endereço IP e Cidade...')
         cityid = con.getPK( 'city', 'city_id', 'name', city)
         sql = "update epc set oam_ip = '"+ip+"', fk_city_cidade_id = '"+str(cityid)+"' where epc_name = '"+epc+"'" 
         if con.manipulatedb(sql):
            logger.debug('IP inserido no EPC %s' %(epc))
            return True
      else:
         logger.debug('Endereço IP encontrado: %s' %(oamip))
      return True


def insertdbHSSUsers(con,hss,datecollected,module,epc,plan,users):
   '''
      insertdbHSSUsers - função para inserir um dados de usuários do HSS 
        Versão: 1.0
        Adicionado em: 24/08/2017 (Diogenes)

        @param con  - conexão com o banco de dados
        @param hss  - nome do HSS
        @param datecollected - data em que o log com os dados de usuários foram coletados
        @param module - módulo do HSS de armazenamento de dados
        @param epc  - nome do EPC que os usuários pertencem. 
                      Exceções: OTHERS  - para usuários em que o EPC não foi identificado
                               NOEPC   - usuários ativos não estão conectados em nenhum EPC
                               PREPROV - usuários pré-provisionados
        @param plan  - nome do plano/produto dos usuários 
        @param users - quantitativo de usuários
        @returns - FALSE ou TRUE
   '''
   hssid = con.getPK( 'hss', 'hss_id', 'hss_name', hss)
   epcid = con.getPK( 'epc', 'epc_id', 'epc_name', epc)
   ausers = con.consultdb("select users from hss_users where hss_id="+str(hssid)+" and date_collected='"+datecollected+"' and module = "+str(module)+" and epc_id="+str(epcid)+" and plan='"+plan+"'")
   if (ausers is None) or (not ausers):
      logger.debug('Nenhum dado existente. Inserindo dados')
      sql = "insert into hss_users (hss_id, date_collected, module, epc_id, plan, users) values ("+str(hssid)+",'"+datecollected+"',"+str(module)+","+str(epcid)+",'"+plan+"',"+str(users)+")"
   else:
      logger.debug('Dado existente. Atualizando dados')
      tusers = int(ausers[0][0]) + int(users)
      sql = "update hss_users set users = "+str(tusers)+" where hss_id="+str(hssid)+" and date_collected='"+datecollected+"' and module="+str(module)+" and epc_id="+str(epcid)+" and plan='"+plan+"'"
   if con.manipulatedb(sql):
      logger.debug('Feito!')
      return True
   else:
      return False


def insertdbSite(con,site,plmn,enodebId,ip_ctrl):
   '''
      insertdbSite - função para inserir dados de sites
        Versão: 1.0
        Adicionado em: 27/08/2017 (Diogenes)

        @param con  - conexão com o banco de dados
        @param site  - nome do site
        @param plmn - plmn ao qual o site pertence
        @param enodebID - id da enodeB do site
        @param ip_ctrl  - endereço IP CTRL
        @param city  - cidade onde o site está localizado
        @returns - FALSE ou TRUE
   '''
   import ipaddress
   siteid = con.getPK( 'site', 'site_id', 'site_name', site)
   if siteid is None:
      logger.info('Consulta cidade')
      cityid = get_city_site(con,enodebId)
      ip_user = str(ipaddress.ip_address(unicode(ip_ctrl)) - (32 * 256))
      ip_oam = str(ipaddress.ip_address(unicode(ip_ctrl)) + (64 * 256))
      sql = "insert into site (site_name, plmn, enodeb_id, site_user_ip, site_ctrl_ip, site_oam_ip, fk_city_city_id) values ('"+site+"',"+plmn+","+enodebId+",'"+ip_user+"','"+ip_ctrl+"','"+ip_oam+"',"+str(cityid)+")"
      if con.manipulatedb(sql):
         return True
   else:
      return True

def insertdbTrafficSite(con,epc,site,dt,users):
   '''
      insertdbTrafficSite - função para inserir dados de tráfego de sites
        Versão: 1.0
        Adicionado em: 27/08/2017 (Diogenes)

        @param con  - conexão com o banco de dados
        @param epc  - nome do epc onde o site está filiado
        @param site - nome do site
        @param dt - timestamp de execução da coleta de dados
        @param users - quantidade de usuários conectados no site
        @returns - FALSE ou TRUE
   '''
   siteid = con.getPK( 'site', 'site_id', 'site_name', site)
   if siteid is not None:
      logger.info('Consulta EPC "%s"' %(epc))
      epcid = con.getPK( 'epc', 'epc_id', 'epc_name', epc)
      if epcid is None:
         logger.error('EPC "%s" não localizado no BD' %(epc))
         return False
      sql = "insert into traffic_site (site_id, date_collected, users, fk_epc_epc_id) values ("+str(siteid)+",'"+str(dt)+"',"+str(users)+","+str(epcid)+")"
      if con.manipulatedb(sql):
         return True
   else:
      return True


def insertdbTrafficEPC(con,epc,dt,inputgbps,outputgbps):
   '''
      insertdbTrafficEPC - função para inserir dados de tráfego de EPCs
        Versão: 1.0
        Adicionado em: 28/08/2017 (Diogenes)

        @param con  - conexão com o banco de dados
        @param epc  - nome do epc 
        @param dt - timestamp de execução da coleta de dados
        @param inputgbps - tráfego de entrada do EPC [Gbps]
        @param outputgbps - tráfego de saída do EPC [Gbps]
        @returns - FALSE ou TRUE
   '''
   epcid = con.getPK( 'epc', 'epc_id', 'epc_name', epc)
   if epcid is not None:
      sql = "insert into traffic_epc (epc_id, date_collected, input_gbps, output_gbps) values ("+str(epcid)+",'"+str(dt)+"',"+str(inputgbps)+","+str(outputgbps)+')'
      if con.manipulatedb(sql):
         return True
   else:
      return True

def updateTraffic(con,dt):
   '''
      updateTraffic - função para atualização de dados de tráfego dos EPCs e Sites
        Versão: 1.0
        Adicionado em: 30/08/2017 (Diogenes)

        @param con  - conexão com o banco de dados
        @param dt - Timestamp do início de execução do script
        @returns - FALSE ou TRUE
   '''
   sql="select epc_id from traffic_epc where date_collected = '"+str(dt)+"'"
   repc = con.consultdb(sql)
   if (repc is not None) or (repc):
      for epcid in repc:
          # Atualização de dados de tráfego do EPC
          sql = "select sum(users) from traffic_site where fk_epc_epc_id = "+str(epcid[0])+" and date_collected = '"+str(dt)+"'"
          epcusers = con.consultdb(sql)[0][0] 
          sql = "select (input_gbps + output_gbps) from traffic_epc where epc_id = "+str(epcid[0])+" "\
                "and date_collected = '"+str(dt)+"'"
          trafficepc = con.consultdb(sql)[0][0] 
          trafficusers = 0 if epcusers == 0 else (trafficepc*(10**6)/epcusers)
          sql = "update traffic_epc set users = "+str(epcusers)+", "\
                "traffic_avguser_kbps = "+str(trafficusers)+" "\
                "where epc_id ="+str(epcid[0])+" and date_collected = '"+str(dt)+"'"
          rtrafficepc = con.manipulatedb(sql)
          # Atualização dados de tráfego dos sites
          sql = "update traffic_site set traffic_mbps = (users * "+str(trafficusers)+")/1000 "\
                "where fk_epc_epc_id ="+str(epcid[0])+" and date_collected = '"+str(dt)+"'"
          rupsite = con.manipulatedb(sql)

def get_city_site(con,enodebid):
   '''
      get_city_site - função para buscar id da cidade de um site
        Versão: 1.0
        Adicionado em: 30/08/2017 (Diogenes)

        @param con  - conexão com o banco de dados
        @param enodebid - Id da enodeB
        @returns - FALSE ou TRUE
   '''
   sql="select a.city_id from city as a, site as b "\
        "where a.city_id = b.fk_city_city_id "\
        "and b.enodeb_id = '"+enodebid+"';"
   rs = con.consultdb(sql)
   if (rs is not None) and (rs):
      print rs
      return rs[0][0]
   else:
      return 99999   # Cidade: Não Determinado

def updatedbSiteCity(con,lookupdata):
   '''
      updatedbSiteName - função para atualizar o nome das cidades dos sites
        Versão: 1.0
        Adicionado em: 30/08/2017 (Diogenes)

        @param con  - conexão com o banco de dados
        @param lookupdata  - dados dos sites
        @returns - FALSE ou TRUE
   '''
   for s in lookupdata.split('\n'):
      try:
          if not s.startswith("#"):
             sql = "select fk_city_city_id from site where enodeb_id = "+s.split('\t')[1]
             rs = con.consultdb(sql)
             if (rs is not None) and (rs):
                if rs[0][0] == 99999: 
                   sql = "update site set fk_city_city_id = (select city_id from city where name = '"+s.split('\t')[2]+"') "\
                         "where enodeb_id ="+s.split('\t')[1]
                   rupcity = con.manipulatedb(sql)
      except Exception, e:
          logger.error('Erro no parser.', exc_info=True)
          continue
