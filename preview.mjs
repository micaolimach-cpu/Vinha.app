import {spawn} from 'node:child_process';
import {existsSync} from 'node:fs';
const bundled='/opt/codex/runtimes/codex-primary-runtime/dependencies/python/bin/python';
const python=process.env.PYTHON_BIN||process.env.CODEX_PRIMARY_RUNTIME_PYTHON||(existsSync(bundled)?bundled:'python3');
const proc=spawn(python,['app.py',...process.argv.slice(2)],{stdio:'inherit',env:{...process.env,APP_ENV:'demo',DATA_DIR:process.env.DEMO_DATA_DIR||'/tmp/vinha-preview'}});
proc.on('error',e=>{process.stderr.write('Python preview unavailable: '+e.message+'\n');process.exit(1)});
proc.on('exit',code=>process.exit(code??0));
process.on('SIGTERM',()=>proc.kill());
