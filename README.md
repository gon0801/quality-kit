# quality-kit

Cinco capas de calidad que se suman a lo que ya tenes con SummonAI Kit
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
4. **Revision cruzada entre IAs** (`cross-review.ps1`): para un cambio
   delicado, le pedis a una IA DISTINTA de la que escribio el cambio que lo
   revise con ojos frescos, de forma independiente.
5. **Auditoria de documentacion** (`docs-groom`, una skill para las 3 IAs):
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
  y el flujo que limita cada bloque a una ronda consolidada de revision,
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

## 4. Revision cruzada entre IAs -- `cross-review.ps1`

Para un cambio delicado (algo que te preocupa, algo grande, algo tocando
dinero o datos sensibles), pedile a una IA DISTINTA que revise el trabajo
de la que lo escribio -- una segunda opinion independiente y con ojos
frescos, no la misma IA revisandose a si misma.

```
pwsh -NoProfile -File ./cross-review.ps1 -Con kimi
pwsh -NoProfile -File ./cross-review.ps1 -Con codex -Alcance staged
pwsh -NoProfile -File ./cross-review.ps1 -Con claude -Alcance last-commit
pwsh -NoProfile -File ./cross-review.ps1 -Con grok
pwsh -NoProfile -File ./cross-review.ps1 -Con qwen
pwsh -NoProfile -File ./cross-review.ps1 -Con auto -Excluir kimi
pwsh -NoProfile -File ./cross-review.ps1 -Con auto -Excluir kimi -Archivos "engines/bid_motor.py,tests/test_bid_motor.py"
```

- `-Con` (obligatorio): que IA hace la revision -- `kimi`, `codex`,
  `claude`, `glm`, `grok`, `qwen`, o `auto`.
- `-Con auto`: prueba la cadena `claude -> glm -> grok -> kimi -> qwen -> codex` (el cerebro mas
  fuerte primero) y usa el PRIMERO que entregue una revision de verdad,
  saltando al que pongas en `-Excluir` (la IA que escribio el cambio: una
  IA no debe revisar su propio trabajo). Si un candidato no esta instalado
  o falla, pasa al siguiente sin frenarte; si NINGUNO responde, sale con
  codigo 3 para que quien llamo (por ejemplo, el harness de SummonAI) caiga
  a su revisor interno y lo diga en su reporte. Al final anuncia el
  "Revisor efectivo" para que quede claro quien reviso de verdad.
  Nota de diseno: `claude` se invoca SIEMPRE con las variables de entorno
  `ANTHROPIC_*` y `CLAUDE_CODE_USE_*` limpias -- asi una redireccion por
  variables (una sesion lanzada con `glm`, o los toggles de Bedrock/Vertex)
  no desvia la revision: va a la cuenta real de Claude, con el modelo
  default del plan (que mejora solo cuando Anthropic actualiza el plan, sin
  tocar nada aca). Limite honesto: esto cubre redirecciones por variables
  de entorno; un binario `claude` falso plantado en el PATH ya seria una
  maquina comprometida, fuera del alcance de este script. Y si algun dia no
  hay suscripcion de Claude, la cadena baja sola al siguiente cerebro
  disponible. El codigo de salida 3 como senal de "sin revisor externo"
  aplica SOLO al modo `auto`; en modo directo el codigo del CLI se propaga
  tal cual, con UNA excepcion deliberada: salir con 0 pero sin decir nada
  se convierte en codigo 1, porque una revision vacia no es una revision.
  Dos consecuencias asumidas de la limpieza de variables (que aplica a
  TODA invocacion de claude, tambien `-Con claude` directo): en una maquina
  donde claude se autentique SOLO por ANTHROPIC_API_KEY (sin login OAuth),
  claude va a fallar aqui a proposito -- en `auto` la cadena baja sola al
  siguiente; y quien dependa de Bedrock/Vertex como unico acceso vera lo
  mismo. En esta maquina el login es OAuth, asi que nada de esto aplica
  hoy.
  Este modo es el que usa el harness de SummonAI en los hosts que no son
  Claude (Kimi, Codex, GLM): su gate de Review corre esto y le pega los
  hallazgos a su revisor -- codigo escrito por un modelo menor siempre pasa
  por el criterio del modelo mas fuerte disponible antes de cerrar.
- `-Alcance` (opcional): que diferencias revisar.
  - `staged`: lo que ya hiciste `git add`.
  - `working`: lo que todavia NO hiciste `git add`.
  - `last-commit`: el ultimo commit ya hecho.
  - si no lo pasas: la combinacion de `staged` + `working` (todo lo que
    todavia no esta commiteado).
- `-Archivos` (opcional): limita el diff a esos archivos (pathspecs
  relativos a la raiz del repo, separados por coma en un solo argumento;
  acepta backslashes de Windows y los normaliza). Nacio de una falla real
  (retro Kimi 2026-07-09): un working tree con CUATRO fixes acumulados
  produjo un diff tan grande que el revisor externo murio por timeout dos
  veces (>300 s) sin entregar nada -- con el scope de la tarea en curso el
  diff queda chico y los hallazgos relevantes. Combinable con `-Alcance`.
  OJO: una ruta mal tipeada da diff vacio en silencio; por eso el mensaje
  de "no hay diferencias" nombra el scope pedido, para que el typo se vea.
- `-DryRun`: muestra el comando y el mensaje que se le mandaria a la IA,
  sin llamarla de verdad (util para probar sin gastar cuota).

El diff se recorta a unos 60KB antes de mandarlo (con un aviso al final si
se recorto) para no saturar el mensaje. El diff en si se guarda en un
archivo temporal (fuera del repo, en la carpeta temporal del sistema) y se
le pide a la IA que lo lea de ahi -- esto evita el limite de longitud que
tiene Windows para un solo argumento de linea de comandos (unos 32.000
caracteres), que un diff de 60KB superaria facil si se lo pasaramos
directo como texto. El archivo temporal se borra solo al terminar.

La IA responde con una lista numerada de hallazgos (cada uno con severidad
alta/media/baja) o, si no encuentra nada que objetar, la palabra `LGTM`.

### Como se invoca cada CLI

kimi, claude y codex fueron probadas de verdad (no solo leyendo su
documentacion) con diffs de ejemplo, varias veces cada una. grok y
qwen estan cableadas contra sus flags headless documentados; todavia
no tienen una ronda en vivo con un diff real:

- **kimi -p**: funciona directo, sin nada especial que configurar. Rapido
  (segundos) incluso pidiendole una revision real con hallazgos.
- **claude -p**: funciona directo, sin nada especial que configurar.
  Rapido, y en la prueba en vivo devolvio una revision real con hallazgos
  concretos (una funcion nueva sin prueba, un problema de formato, un
  detalle de fin de linea).
- **codex exec**: funciona (confirmado con resultados reales de revision,
  no solo un saludo), PERO con dos particularidades que hay que conocer:
  1. En Windows, un shim `.cmd` se lanza mediante `cmd.exe /c`; en macOS y
     Linux se ejecuta directamente el launcher nativo encontrado en `PATH`.
     `cross-review.ps1` elige ambas rutas automaticamente.
  2. Una de tiempos de respuesta, que NO tiene arreglo desde este kit: en
     las pruebas en vivo, `codex exec` para una revision real tardo desde
     unos 10-25 segundos hasta mas de 10 minutos para tareas de
     complejidad comparable, sin ningun error -- solo mas lento. Esto
     coincide con que esta instalacion de Codex tiene configurados varios
     servidores MCP (Playwright, Context7, sequential-thinking, entre
     otros) que se intentan levantar en cada invocacion, mas un nivel de
     razonamiento alto por defecto; ninguna de las dos cosas es algo que
     `cross-review.ps1` controle. Si `-Con codex` tarda mucho, es
     esperable, no un cuelgue del script -- pero si preferis una revision
     rapida, `kimi` o `claude` fueron mas predecibles en las pruebas.

- **grok -p**: headless single-turn (`--single`). Se lanza con
  `--no-subagents`, `--disable-web-search`, `--always-approve` y un
  allowlist de herramientas de solo lectura (`read_file,grep,list_dir`)
  para que pueda verificar codigo fuera del diff sin editar y sin
  colgarse en un prompt de permisos. Cableado contra la CLI real; no es una prueba en vivo con un diff
  real -- esa queda para cuando se use de verdad.
- **qwen -p**: no interactivo, con `-y` y `-o text`. Su configuracion global
  debe excluir las herramientas de escritura, tal como explica el comentario
  del script. En Windows acepta el shim `.cmd`; en macOS y Linux usa el
  launcher nativo. Tampoco tiene prueba en vivo con un diff real todavia.

Ver la seccion de troubleshooting mas abajo para mas detalle sobre estos
dos puntos de Codex, y por si en tu maquina especifica `codex` pide
confirmar la confianza del directorio la primera vez (no paso en las
pruebas en vivo de este kit, pero queda documentado por si aparece en otro
repo o maquina).

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
   bateria completa una sola vez por bloque sobre el commit final. La evidencia
   de CI para el mismo SHA no se repite localmente.
4. Los hallazgos de revision se agrupan en una sola ronda por bloque. Para
   cambios delicados, sugerir revision cruzada
   (`cross-review.ps1`).
5. Una observacion tardia menor no reabre el ciclo; el checklist posterior al
   deploy se ejecuta una sola vez mientras el SHA no cambie.
6. Si el repo no tiene kit de calidad, sugerir `init-repo.ps1` una vez
   (sin insistir).

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

### Codex pide confirmar la confianza del directorio

Si `cross-review.ps1 -Con codex` (o `codex exec` directo) se queda
esperando algo o falla mencionando confianza/trust del directorio, abri
`codex` de forma interactiva una vez, adentro del repo en cuestion, y
acepta la confianza cuando te la pida. Una vez hecho eso para ese repo,
`codex exec`/`cross-review.ps1 -Con codex` van a funcionar sin pedir nada
mas ahi. En las pruebas en vivo de este kit no volvio a pedirse esa
confirmacion, pero queda documentado por si en otra maquina o otro repo si
aparece.

### Codex tarda mucho, o parece colgado

Confirmado en vivo: para una revision real (no un simple saludo), `codex
exec` tardo en las pruebas desde unos 10-25 segundos hasta mas de 10
minutos en corridas distintas, con exactamente el mismo tipo de tarea, sin
ningun error en el medio -- solo mas lento. Esto no es un cuelgue de
`cross-review.ps1`: el mecanismo de lanzar `codex` funciona (confirmado
repetidas veces, incluyendo corridas rapidas de 9 a 25 segundos con
resultados reales). La variabilidad parece venir de esta instalacion
puntual de Codex, que tiene configurados varios servidores MCP (Playwright,
Context7, sequential-thinking, entre otros) que se intentan levantar en
cada invocacion -- si alguno tarda en responder (por red, por cache fria de
paquetes la primera vez, etc.), toda la invocacion de Codex tarda con el --
sumado a que el nivel de razonamiento por defecto de Codex es alto. Nada de
esto lo controla este kit ni se puede arreglar sin tocar la configuracion
de Codex (que este kit deliberadamente no toca).

Si te pasa: es normal, no un error. Si preferis una respuesta rapida y
predecible, usa `kimi` o `claude` en su lugar -- ambos fueron
consistentemente rapidos (segundos) en las pruebas en vivo, incluso
pidiendoles una revision real con hallazgos concretos.

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
