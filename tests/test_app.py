import unittest, tempfile, os, io, json, sys
from pathlib import Path
from datetime import date,timedelta
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
os.environ['APP_ENV']='demo'
os.environ['DATA_DIR']=tempfile.mkdtemp(prefix='vinha-initial-')
import app

class AppTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();app.DATA=Path(self.tmp.name);app.DEMO=True;app.BASE='';app.initialize()
        self.admin=self.login('admin');self.seller=self.login('seller')
    def tearDown(self):self.tmp.cleanup()
    def call(self,path,method='GET',data=None,session=None,csrf=True):
        route,_,query=path.partition('?');raw=json.dumps(data).encode() if data is not None else b''
        environ={'PATH_INFO':route,'QUERY_STRING':query,'REQUEST_METHOD':method,'CONTENT_LENGTH':str(len(raw)),'wsgi.input':io.BytesIO(raw),'wsgi.url_scheme':'http','HTTP_HOST':'test.local','HTTP_ORIGIN':'http://test.local','REMOTE_ADDR':'127.0.0.1'}
        if session:environ['HTTP_COOKIE']=session['cookie'];environ['HTTP_X_CSRF_TOKEN']=session['csrf'] if csrf else 'invalid'
        result={}
        def start(status,headers):result.update(status=int(status.split()[0]),headers=dict(headers))
        out=b''.join(app.application(environ,start));result['data']=json.loads(out);return result
    def login(self,role):
        r=self.call('/api/demo/login','POST',{'role':role});self.assertEqual(r['status'],200,r)
        s={'cookie':r['headers']['Set-Cookie'].split(';')[0],'csrf':''};me=self.call('/api/me',session=s);s['csrf']=me['data']['csrf'];return s
    def next_day(self):
        d=date.fromisoformat(app.today())+timedelta(days=1)
        while not app.is_business_day(d.isoformat()):d+=timedelta(days=1)
        return d.isoformat()
    def test_access_isolation(self):
        self.assertEqual(self.call('/api/clients')['status'],401)
        self.assertEqual(len(self.call('/api/clients',session=self.seller)['data']['clients']),4)
        self.assertEqual(self.call('/api/team',session=self.seller)['status'],403)
        r=self.call('/api/requests','POST',{'visit_id':5,'proposed_date':self.next_day(),'frequency':'Mensal'},self.seller)
        self.assertEqual(r['status'],404)
    def test_csrf(self):
        r=self.call('/api/team','POST',{'email':'x@example.test','seller_id':1},self.admin,False)
        self.assertEqual(r['status'],403)
    def test_request_and_approval(self):
        r=self.call('/api/requests','POST',{'visit_id':1,'proposed_date':self.next_day(),'frequency':'Mensal','availability':'Terça à tarde','reason':'Ausente'},self.seller)
        self.assertEqual(r['status'],200,r);rid=r['data']['id']
        with app.connection() as db:self.assertEqual(db.execute('SELECT visit_date FROM visits WHERE id=1').fetchone()[0],app.today())
        self.assertEqual(self.call(f'/api/requests/{rid}/review','POST',{'decision':'approve'},self.seller)['status'],403)
        approved=self.call(f'/api/requests/{rid}/review','POST',{'decision':'approve'},self.admin);self.assertEqual(approved['status'],200,approved)
        with app.connection() as db:
            self.assertEqual(db.execute('SELECT visit_date FROM visits WHERE id=1').fetchone()[0],self.next_day())
            self.assertEqual(db.execute('SELECT frequency FROM clients WHERE id=1').fetchone()[0],'Mensal')
            self.assertEqual(db.execute('SELECT status FROM requests WHERE id=?',(rid,)).fetchone()[0],'Aprovada')
    def test_checkin_checkout(self):
        r=self.call('/api/visits/1/checkin','POST',{},self.seller);self.assertEqual(r['status'],200,r)
        self.assertEqual(self.call('/api/visits/2/checkin','POST',{},self.seller)['status'],409)
        self.assertEqual(self.call('/api/visits/1/checkout','POST',{},self.admin)['status'],403)
        self.assertEqual(self.call('/api/visits/1/checkout','POST',{},self.seller)['status'],200)
        with app.connection() as db:
            v=db.execute('SELECT * FROM visits WHERE id=1').fetchone();self.assertEqual(v['status'],'Realizada');self.assertTrue(v['checkin_at']);self.assertTrue(v['checkout_at']);self.assertIsNone(v['checkin_lat'])
    def test_duplicate_import_preserves_manual_edit(self):
        p={'records':[{'cnpj':'12345678000190','name':'Novo cliente','seller':'Ana Martins','channel':'ON-TRADE','city':'Porto Alegre','bairro':'Centro','address':'Rua A','frequency':'Semanal','active':True,'central':True,'dates':[self.next_day()]}],'warnings':[]}
        with app.connection() as db:
            u=dict(db.execute('SELECT * FROM users WHERE id=1').fetchone());a=app.commit_import(db,u,p)
            db.execute("UPDATE clients SET name='Edição manual' WHERE cnpj='12345678000190'");b=app.commit_import(db,u,p)
            self.assertEqual(a['clients_created'],1);self.assertEqual(b['clients_created'],0);self.assertEqual(b['visits_created'],0)
            self.assertEqual(db.execute("SELECT name FROM clients WHERE cnpj='12345678000190'").fetchone()[0],'Edição manual')
    def test_capacity_and_atomic_rejection(self):
        day=self.next_day()
        with app.connection() as db:
            for i in range(10):
                cur=db.execute("INSERT INTO clients(cnpj,name,seller_id,channel,frequency) VALUES(?, ?,1,'OFF-TRADE','Mensal')",(str(i).zfill(14),'Teste '+str(i)))
                db.execute('INSERT INTO visits(client_id,visit_date) VALUES(?,?)',(cur.lastrowid,day))
        r=self.call('/api/visits/1','PATCH',{'visit_date':day,'frequency':'Mensal','version':1},self.admin);self.assertEqual(r['status'],409)
        with app.connection() as db:self.assertEqual(db.execute('SELECT visit_date FROM visits WHERE id=1').fetchone()[0],app.today())
    def test_revocation_invalidates_session(self):
        self.assertEqual(self.call('/api/team/2','DELETE',{},self.admin)['status'],200)
        self.assertEqual(self.call('/api/clients',session=self.seller)['status'],401)
    def test_stale_approval(self):
        r=self.call('/api/requests','POST',{'visit_id':1,'proposed_date':self.next_day(),'frequency':'Mensal'},self.seller);rid=r['data']['id']
        with app.connection() as db:db.execute('UPDATE clients SET version=version+1 WHERE id=1')
        self.assertEqual(self.call(f'/api/requests/{rid}/review','POST',{'decision':'approve'},self.admin)['status'],409)
    def test_one_time_token(self):
        with app.connection() as db:db.execute('INSERT INTO tokens VALUES(?,?,?)',(app.digest('test-one-time'),1,int(app.time.time())+1000))
        first=self.call('/api/auth/verify','POST',{'token':'test-one-time'});self.assertEqual(first['status'],200,first)
        second=self.call('/api/auth/verify','POST',{'token':'test-one-time'});self.assertEqual(second['status'],401)
    def test_production_has_no_demo_login(self):
        app.DEMO=False
        self.assertEqual(self.call('/api/demo/login','POST',{'role':'admin'})['status'],401)
        app.DEMO=True

if __name__=='__main__':unittest.main()
