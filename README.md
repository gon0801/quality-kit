# quality-kit

Cuatro capas de calidad que se suman a lo que ya tenes con SummonAI Kit
(Claude Code, Kimi Code) y a cualquier otra IA que uses (Codex), para que
todo lo que se construya en tus repos quede protegido de la misma forma sin
importar que IA lo escribio:

1. **Candados de commit deterministicos** (`init-repo.ps1`): reglas fijas,
   no negociables, que corren SOLAS en cada commit/push -- no dependen de
   que la IA se acuerde de correrlas.
2. **Regla bug -> prueba de regresion**: cada vez que se arregla un bug,
   el mismo cambio tiene que incluir una prueba que lo hubiera atrapado
   antes. Esto no es una herramienta que se instala; es una regla que se
   suma a las instrucciones globales de cada IA (`install-ai-rules.ps1`).
3. **CI en la nube** (parte de `init-repo.ps1`): los mismos candados,
   corriendo en GitHub Actions, para el dia que empieces a subir tus repos
   a GitHub. Mientras un repo sea solo local, esta capa queda "dormida"
   (no hay nada que romper ni que mantener).
4. **Auditoria de documentacion** (`docs-groom`, una skill para las 3 IAs):
   limpia y reorganiza `CLAUDE.md`/`AGENTS.md`/`docs/` cuando se van
   llenando de contenido viejo o repetido, sin tocar nunca los bloques que
   ya administran otras herramientas (este kit incluido).

Todo esto vive en una carpeta aparte (por ejemplo `~/quality-kit`). No es
parte de ningun repo tuyo: se usa desde afuera, apuntando a cada repo que
quieras proteger. Los comandos de este README usan PowerShell 7 (`pwsh`),
disponible en macOS, Linux y Windows. En Windows PowerShell 5.1 se puede
reemplazar `pwsh` por `powershell`; los scripts conservan compatibilidad con
ambos runtimes.

## 1. Candados de commit -- `init-repo.ps1`

Corre esto UNA VEZ por repo, parado adentro del repo que queres proteger:

```
pwsh -NoProfile -File ./init-repo.ps1
```

Que hace:

- Detecta el stack del repo (Python, Node, o ninguno de los dos) mirando
  archivos reales (`pyproject.toml`, `requirements.txt`, `*.py`,
  `package.json`) -- nunca asume.
- Escribe un `.pre-commit-config.yaml` con los candados que correspondan:
  - **Siempre**: limpieza basica de archivos (espacios finales, fin de
    archivo, conflictos de merge sin resolver, archivos grandes, JSON/YAML
    validos). Tiene sentido en cualquier repo, sin importar el stack.
  - **Python**: `ruff` (lint + formato, una sola herramienta para ambas
    cosas).
  - **Node**: `eslint` y/o `prettier`, pero SOLO si el repo YA tiene su
    propia configuracion de esas herramientas -- nunca se le impone una
    herramienta nueva a un repo que no la usaba.
  - **Pruebas** (si detecta una carpeta de pruebas de Python, o un script
    `test` real en `package.json`): corren en **pre-push**, no en cada
    commit -- las pruebas (sobre todo un backtest o una suite grande) son
    demasiado lentas para cada commit chiquito, pero SI tienen que pasar
    antes de que algo salga del repo hacia afuera. Los hooks de Python usan
    `tools/quality_run_python_tests.py`: en cada maquina elige `uv`, el
    virtualenv Unix/Windows o un Python del sistema, sin guardar la ruta de
    la maquina que genero el YAML.
- Instala los candados de verdad (`pre-commit install`, y
  `pre-commit install --hook-type pre-push` cuando hay pruebas).
- Si el repo ya tiene remoto de GitHub, copia el workflow de CI
  (`.github\workflows\quality.yml`) -- ver la seccion de CI mas abajo. Si
  todavia no tiene remoto (tus repos hoy son locales), lo saltea sin decir
  nada raro; el dia que subas el repo a GitHub, volves a correr
  `init-repo.ps1` y ese paso se activa solo.
- Agrega una seccion "Calidad" a `CLAUDE.md` y `AGENTS.md` del repo
  (los crea si no existen), con los comandos exactos, las reglas de hierro
  y el flujo que limita cada bloque a una ronda consolidada de revision
  (otra solo mientras salgan bloqueantes, cada una sobre los arreglos; lo
  demas a una fila del plan),
  una bateria completa sobre el commit final y un checklist de deploy.

Se puede correr mas de una vez sin problema: nunca pisa una configuracion
de pre-commit que ya tenias de antes (si detecta que `.pre-commit-config.yaml`
no fue generado por quality-kit, no lo toca y te avisa).

### Como elige el runner de pruebas de Python, y por que verifica antes de instalarlo

Leccion de un incidente real (el deploy de MCP-2): asumir que toda carpeta
de pruebas de Python usa `pytest` esta mal -- MCP-2 usa `unittest`, y
ademas `pytest` se rompio en esa maquina con un error interno propio (nada
que ver con el codigo del repo). Un candado de calidad que se rompe es
peor que no tener candado: frena cada push por una razon que no tiene nada
que ver con lo que se esta subiendo. Por eso `init-repo.ps1` ahora:

1. **Elige el runner con esta prioridad, como una cadena de intentos, no
   una sola apuesta**: si hay una config real de pytest (`pytest.ini`,
   `[tool.pytest.ini_options]`, `[tool:pytest]`), prueba pytest primero. Si
   los archivos de la carpeta de pruebas TAMBIEN importan `unittest` o
   heredan de `unittest.TestCase` (el caso real de MCP-2: tiene pytest.ini
   Y pruebas escritas para unittest a la vez), `unittest` queda en cola
   como alternativa por si pytest falla. Si no hay config de pytest pero
   si esa senal de `unittest`, usa `unittest` directo (y si la carpeta esta
   anidada, por ejemplo `app\tests` como en MCP-2, arma el comando para
   entrar primero a esa carpeta). Si no hay ninguna de las dos senales,
   sigue asumiendo pytest (el caso mas comun: pruebas sueltas sin config).
2. **Verifica ANTES de instalar, probando cada candidato en orden**: antes
   de escribir el candado de pre-push, corre el comando elegido una vez de
   verdad. Si falla, prueba el siguiente candidato de la lista (si hay
   alguno). Solo si TODOS los candidatos fallan se rinde: no se instala
   nada, y se imprime una advertencia bien visible nombrando cada runner
   que se probo y por que fallo, con instrucciones de como agregarlo a
   mano una vez arreglado.
3. **Nunca degrada un candado que ya funciona**: si el repo ya tiene un
   candado de pruebas de una corrida anterior (por ejemplo, el que vos
   mismo arreglaste a mano), `init-repo.ps1` lo verifica primero, tal cual
   esta, ANTES de intentar detectar nada de nuevo. Si ese candado
   existente todavia funciona, se mantiene sin cambios -- nunca se
   reemplaza un candado que funciona por nada, ni siquiera si una nueva
   deteccion "en teoria mejor" fallaria. Esto es lo que se rompio en un
   incidente real: una re-corrida probo pytest primero (por prioridad),
   pytest fallo (estaba roto en esa maquina), y la version vieja de esta
   logica se rendia y borraba el candado de unittest que ya funcionaba.

**Nota honesta**: en esta maquina, `pytest` esta roto en general (un error
interno propio de pytest con esta version de Python, no algo que
quality-kit pueda arreglar). Un repo con pruebas genuinamente solo de
pytest (sin senal de `unittest` para caer de alternativa) va a recibir la
advertencia de "candado no instalado" hasta que se actualice pytest o
Python en esta maquina -- eso es el comportamiento correcto y esperado
(fallar seguro), no un bug de quality-kit.

## 2. La regla bug -> prueba de regresion

Esta capa no es una herramienta, es una disciplina: cuando una IA (vos
mismo, o cualquiera de las tres que usas) arregla un bug real, el MISMO
cambio tiene que incluir una prueba automatica que hubiera fallado antes
del arreglo y pasa despues. Sin esa prueba, no hay forma de confirmar que
el bug no vuelva a aparecer mas adelante sin que nadie se de cuenta.

Esta regla se instala como parte de las instrucciones globales de cada IA
(ver `install-ai-rules.ps1` mas abajo) -- aplica a TODOS tus repos
automaticamente, no hace falta repetirla por repo.

## 3. CI en la nube -- estado "dormida" hasta que haya GitHub

`init-repo.ps1` copia `.github\workflows\quality.yml` (que corre los mismos
candados de pre-commit, mas las pruebas, en Ubuntu, en la nube) SOLO si el
repo ya tiene un remoto de GitHub configurado. Mientras tus repos sean
locales (como son hoy), esta capa simplemente no se activa -- no genera
ningun archivo, no hay nada corriendo, no hay nada que mantener ni que
pueda romperse. El dia que subas un repo a GitHub (`git remote add origin
https://github.com/...`), volves a correr `init-repo.ps1` una vez mas y
ese workflow aparece solo, protegiendo el repo tambien en la nube: cualquier
push o pull request corre los mismos chequeos, incluso si viniera de una
maquina sin estos candados instalados.

## Instrucciones globales para las 3 IAs -- `install-ai-rules.ps1`

Este script SI lo tenes que correr vos mismo (no una IA por vos): toca los
archivos de configuracion global de cada IA, y por diseno ninguna IA
deberia poder tocar esos archivos por su cuenta.

```
pwsh -NoProfile -File ./install-ai-rules.ps1
```

Agrega una seccion corta "REGLAS DE CALIDAD (quality-kit)" a:

- `~/.claude/CLAUDE.md`
- `~/.codex/AGENTS.md` (lo crea si todavia no existe)
- `~/.kimi-code/AGENTS.md`

con estas reglas:

1. Si el repo tiene candados de commit, correrlos antes de dar por
   terminado -- nunca usar `--no-verify` ni saltearlos.
2. Cada bug arreglado incluye, en el mismo cambio, una prueba de
   regresion.
3. Durante la implementacion se corren pruebas focalizadas; se ejecuta la
   bateria completa una sola vez por bloque sobre el commit final. Si commit,
   push o CI ya validaron el mismo SHA, esos checks no se repiten manualmente.
4. Los hallazgos de revision se agrupan y corrigen en una sola ronda por
   bloque. Solo un hallazgo BLOQUEANTE (seguridad, datos, una regla
   innegociable, el comportamiento pedido roto o una prueba que no
   discrimina), con el comando que lo reproduce, reabre el ciclo. Un
   bloqueante nunca va a una fila del plan ni se mergea abierto: se corrige,
   o se para y decide el operador. Lo no bloqueante se corrige en la misma
   ronda si es de una linea y, si no, va a una fila del plan y se nombra en
   el PR.
5. Una observacion tardia no bloqueante va a una fila del plan y no reabre el
   ciclo; el checklist posterior al deploy se ejecuta una sola vez mientras el
   SHA no cambie.
6. Si el repo no tiene kit de calidad, sugerir `init-repo.ps1` una vez
   (sin insistir).

8. CI: la bateria completa corre en jobs paralelos cuya union es la
   bateria (con candado); si un job pasa de ~10 min se shardea, nunca se
   recorta ni se saltea por tipo de cambio. Checks de docs/ledger en un
   job propio. Carril: docs/chore/cierre = fast; codigo = gate. Cierres de
   ledger de un bloque = un PR.

Es idempotente (correrlo de nuevo no duplica nada) y deja una copia de
seguridad con fecha antes de tocar cada archivo.

Para sacar esta seccion despues, si alguna vez queres:

```
pwsh -NoProfile -File ./uninstall-ai-rules.ps1
```

## Auditoria de documentacion -- `docs-groom` (skill para las 3 IAs)

Con el tiempo, `CLAUDE.md`/`AGENTS.md`/`docs/` de un repo se van llenando de
contenido viejo, repetido, o de sesiones pasadas. `docs-groom` es una skill
(no un script que corres vos) que le pedis a cualquiera de tus 3 IAs que
audite y reorganice esa documentacion: `CLAUDE.md` queda como punto de
entrada corto (resumen, estructura, reglas criticas, enlaces), `AGENTS.md`
se enfoca en como trabajar en el repo, y el detalle se mueve a `docs/`.
Termina siempre con un reporte de que se reorganizo, que se elimino, que se
creo, y que necesita revision manual.

Tiene 3 reglas de seguridad que no se negocian:

1. **Nunca toca un bloque administrado** (marcado con `>>> ... START` /
   `... END`, o un comentario "managed by" -- esto incluye las secciones que
   el propio quality-kit y SummonAI Kit ya administran).
2. **Historia con valor se muda, no se borra** -- va al tracker del repo
   (`STATUS.md`) o queda en el historial de git; solo se elimina lo que de
   verdad no aporta nada.
3. **Verifica contra el codigo real antes de borrar algo por "obsoleto"** --
   si no se puede confirmar, se deja y se marca para revision manual en vez
   de borrarlo.

Instalarla (correlo vos mismo, una IA no deberia tocar la configuracion de
otra IA por su cuenta):

```
pwsh -NoProfile -File ./install-docs-groom.ps1
```

Esto agrega la skill a las 3 IAs: `~/.claude/skills/docs-groom/`,
`~/.codex/skills/docs-groom/`, y `~/.kimi-code/skills/docs-groom/`. Reinicia
(o abri una sesion nueva en) cada asistente despues para que la detecte, y
pedile algo como "usa la skill docs-groom para limpiar la documentacion de
este repo".

El formato de Kimi se confirmo en vivo (no solo leyendo su documentacion):
se armo una skill de prueba con este mismo contenido, se cargo con
`kimi --skills-dir` apuntando a una carpeta descartable, y Kimi la listo
correctamente bajo sus skills de usuario, con el nombre y la descripcion
bien interpretados. El formato de Codex se tomo de una de sus propias
skills de SummonAI Kit ya instaladas (mismo formato que Claude: front
matter YAML con `name`/`description`/`allowed-tools`). Kimi no tiene
`allowed-tools` en su front matter a proposito -- es un campo que Claude y
Codex usan pero que, segun el propio codigo fuente de Kimi, no interpreta
de la misma forma.

Para sacarla despues:

```
pwsh -NoProfile -File ./uninstall-docs-groom.ps1
```

## CI Linux para suites bash -- `install-ci-linux.ps1`

Para repos cuya suite de tests son scripts de shell. En Git Bash/MSYS2 cada
fork de subproceso cuesta ~28 ms; en Linux ~0.1 ms (~300x). Medido en
summonaikit-claude (fila 10.5 de su Plans.md): la misma suite pasa de ~18 min
en Windows a ~1-2 min en ubuntu-latest. Este installer escribe
`.github\workflows\suite-linux.yml` con un job que corre la suite completa en
cada push a main/master y en cada PR (el mismo criterio que el `quality.yml`
de `init-repo.ps1`, para no duplicar corridas push+PR; una rama protegida con
otro nombre requiere editar `branches:` a mano).

```
pwsh -NoProfile -File ./install-ci-linux.ps1 -RepoPath <repo> `
    [-TestEntry tests/run.sh] [-TimeoutMinutes 30] [-EnvVar "SAIKIT_CI_LINUX=1,OTRA=valor"]
```

- Solo aplica a suites bash: si no existe el entrypoint (`tests/run.sh` por
  default, otro con `-TestEntry`), se rehusa. Los repos con suite PowerShell
  (este kit), pytest o jest no pagan el impuesto de MSYS2 -- les basta el
  `quality.yml` de `init-repo.ps1`.
- Tests atados a Windows: el runner del repo debe saltearlos DECLARANDOLOS
  (nombrados uno por uno en su salida, detras de una variable pasada con
  `-EnvVar`), nunca en silencio -- `not_observed != absent`.
- Idempotente: refresca su propio workflow (marca de propiedad); un
  `suite-linux.yml` escrito a mano se respeta y no se toca.
- Candidato tipico: summonaikit-kimi (mismo molde de tests que
  summonaikit-claude).
- `-Shards N` (N>=2): matrix `1/N..N/N` con `SAIKIT_SHARD` y un job
  agregador `gate` (`if: always()`). Sin `-Shards`, un job como hoy. El
  instalador se niega si el `run.sh` del repo no menciona `SAIKIT_SHARD`
  (no dejar un workflow que falla en cada push).

## CI paralelo (regla 8)

La bateria completa corre en jobs paralelos cuya UNION es la bateria (con
candado). Nunca se recorta ni se saltea por tipo de cambio. Si un job pasa
de ~10 min se shardea: bash `SAIKIT_SHARD=i/N`, pytest `-n auto`
(pytest-xdist; opt-out `QUALITY_KIT_PYTEST_SERIAL=1` al correr
`init-repo.ps1`), jest/vitest `--shard`. Los checks que leen docs o ledger
reales van en un job `gate` propio de segundos (los checkers corren sin
args y sin deps extra: solo stdlib / bash). Carril: docs/chore/cierre =
fast (bots + lead); codigo = gate (+ reviewer). Los cierres de ledger de
un bloque van en un solo PR.

Para refrescar repos existentes (idempotente):

```
pwsh -NoProfile -File ./install-ai-rules.ps1
pwsh -NoProfile -File ./new-repo.ps1 -RepoPath <repo>
```

`install-ai-rules.ps1` lo corre el operador (toca los archivos globales de
IA). `new-repo.ps1` refresca la seccion Calidad del repo. Suites bash:
`install-ci-linux.ps1 -RepoPath <repo> -Shards N` si el `run.sh` ya honra
`SAIKIT_SHARD`. Un `quality.yml` generado por el kit que ya no coincide con
la plantilla actual (edicion o plantilla vieja) no se pisa; para adoptar
la plantilla nueva, borralo y re-corre `new-repo.ps1`.

## Politica de push a ramas protegidas -- `install-branch-push-policy.ps1`

El guardrail del plugin claude-code-harness lee
`<repo>\.claude-code-harness.config.yaml`; con el default (`ask`), cada push
directo a master deja un prompt colgado cuando el operador no esta (medido
2026-08-15: fue uno de los bloques grandes de una task de 18 h de pared). El
fallback (`harness.toml` en la raiz versionada del plugin) muere en cada
update del plugin; el lugar correcto es el yaml del repo, commiteado.

```
pwsh -NoProfile -File ./install-branch-push-policy.ps1 -RepoPath <repo> [-Mode allow|ask]
```

- **Para el operador, no para una sesion de IA**: el harness le bloquea al
  agente escribir ese archivo (control-plane), y esta bien que asi sea -- un
  agente no desarma sus propios candados. Corre el script vos.
- **Repos nuevos**: no hace falta correrlo a mano -- `init-repo.ps1` (y por
  lo tanto `new-repo.ps1`) lo instala solo con `allow` cuando deja la red
  armada (candados de pre-commit + remoto de GitHub + workflow de CI). Sin
  esa red lo saltea con aviso, porque un allow desnudo no presupone nada.
- `allow` (default) solo tiene sentido si el repo tiene OTRA red sobre la
  rama protegida: pre-commit + un job de CI en cada push (`init-repo.ps1` +
  `install-ci-linux.ps1`). Sin esa red, usa `-Mode ask`.
- Sobre un config existente edita quirurgicamente (backup fechado previo):
  cambia solo el valor de `protected_branch_push`, o inserta la clave en la
  seccion `safety:` existente, sin tocar el resto.

## Troubleshooting

### El repo no tiene candados todavia

Si le pedis a una IA que revise un cambio y el repo no tiene
`.pre-commit-config.yaml`, va a sugerir correr `init-repo.ps1` una vez
(por la regla 4 de `install-ai-rules.ps1`). Es una sugerencia unica, no
deberia insistir en cada respuesta.

### Un repo ya tenia su propia configuracion de pre-commit

`init-repo.ps1` nunca pisa un `.pre-commit-config.yaml` que no haya
generado el mismo -- si ya tenias uno propio, lo deja intacto y te avisa
por consola. La seccion "Calidad" que agrega a `CLAUDE.md`/`AGENTS.md` en
ese caso tambien lo aclara, en vez de listar candados que en realidad no
estan activos.

### Le agregaste algo a mano dentro de `.pre-commit-config.yaml`

Tambien es seguro: `init-repo.ps1` compara lo que generaria hoy contra el
archivo existente antes de reescribirlo. Si encuentra cualquier diferencia
(un `exclude:` que agregaste, un comentario explicandolo, un hook nuevo,
args editados), NO reescribe nada -- deja el archivo tal cual esta y avisa
por consola "Config personalizado detectado", listando las lineas que no
reconoce. No fusiona nada solo; si el kit necesita actualizar sus propios
fragmentos ahi, la fusion es a mano. (Ojo: esto tambien significa que si
el stack de tu repo cambia -- por ejemplo, agregas el primer archivo
Python -- y el archivo ya tenia algun agregado propio o ya no coincide
byte a byte con lo que el kit generaria hoy, tampoco se actualiza solo;
borralo y volve a correr `init-repo.ps1` si queres que se regenere desde
cero con los candados del nuevo stack.)
