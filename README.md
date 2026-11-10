
# Universal Builder

Universal Builder é um orquestrador de compilação desenvolvido em Bash para organizar, analisar, verificar e compilar projetos de diferentes tecnologias.

O projeto trabalha com perfis de compilação e utiliza ferramentas armazenadas em seu próprio diretório. Para projetos Android, possui descoberta automática de versões e adaptadores especializados para projetos Gradle e Android NDK legado.

## 1. Recursos

### Recursos implementados

- Detecção automática do perfil de projetos.
- Criação automática de `builder.conf` a partir dos modelos disponíveis.
- Clonagem de projetos Git.
- Análise de requisitos e versões.
- Descoberta de ferramentas Android internas.
- Verificação de dependências por perfil.
- Seleção de SDK, plataforma Android, Build Tools, JDK e Gradle.
- Compilação Android por adaptadores especializados.
- Execução de comandos de compilação configurados pelo usuário.
- Coleta de artefatos gerados.
- Organização das saídas por projeto.
- Assistente interativo para preparar projetos.

### Perfis disponíveis

| Perfil | Tecnologia |
|---|---|
| `android-native` | Android Java, Gradle e NDK legado |
| `cpp` | C++ |
| `java` | Java |
| `python` | Python |
| `linux` | Aplicações e projetos Linux |

## 2. Requisitos básicos

O ambiente precisa possuir:

- Bash
- Git
- Python 3
- `find`
- `grep`

Cada perfil possui dependências adicionais.

O comando `doctor` verifica os comandos básicos e apresenta os diretórios utilizados pelo Builder.

```bash
./builder.sh doctor
```

A verificação de dependências específicas deve ser feita com:

```bash
./builder.sh check CAMINHO_DO_PROJETO
```

## 3. Instalação do Universal Builder

Clone ou copie o projeto para o diretório desejado.

Entre na pasta:

```bash
cd Universal-Builder
```

Dê permissão de execução aos scripts:

```bash
chmod +x builder.sh
chmod +x builders/*.sh
chmod +x core/*.sh
chmod +x profiles/*/check.sh
```

Confira a instalação:

```bash
./builder.sh help
./builder.sh doctor
```

O Universal Builder não instala SDKs, NDKs, JDKs ou Gradle automaticamente. As ferramentas necessárias precisam ser baixadas, extraídas e organizadas manualmente dentro de `tools/`.

## 4. Instalação manual das ferramentas Android

O Universal Builder procura as ferramentas dentro de `tools/`.

Não basta instalar SDK, NDK ou Java no sistema: a descoberta automática rejeita diretórios externos à pasta interna de ferramentas.

### 5 Android SDK

Página oficial:

https://developer.android.com/studio

Baixe as Android SDK Command-line Tools e extraia os componentes necessários.

O SDK deve ficar organizado assim:

```text
tools/
└── android-sdk/
    ├── cmdline-tools/
    │   └── latest/
    │       └── bin/
    │
    ├── platforms/
    │   ├── android-21/
    │   └── android-28/
    │
    ├── build-tools/
    │   ├── 21.1.0/
    │   └── 28.0.3/
    │
    └── licenses/
```

As versões das plataformas e Build Tools dependem dos requisitos dos projetos.

Para instalar componentes adicionais, utilize o `sdkmanager` fornecido pelas Command-line Tools, apontando para o SDK interno.

Exemplo:

```bash
tools/android-sdk/cmdline-tools/latest/bin/sdkmanager \
    --sdk_root=tools/android-sdk \
    "platform-tools" \
    "platforms;android-28" \
    "build-tools;28.0.3"
```

A versão 28.0.3 das Build Tools é necessária atualmente para o adaptador Android Gradle realizar o alinhamento e a assinatura dos APKs.

### 5.1 Android NDK

Página oficial:

https://developer.android.com/ndk/downloads

Baixe uma distribuição do NDK compatível com o projeto e com o ambiente Linux utilizado.

O Builder procura recursivamente o executável `ndk-build` dentro de:

```text
tools/android/
```

Exemplo de organização:

```text
tools/
└── android/
    └── ndk-r17c/
        └── android-ndk-r17c/
            ├── ndk-build
            ├── build/
            ├── platforms/
            └── toolchains/
```

O executável `ndk-build` precisa ter permissão de execução.

O NDK é necessário para projetos que utilizam código nativo. Entretanto, o adaptador Android legado atualmente exige que o NDK seja localizado mesmo quando não encontra `Android.mk`.

### 5.2 Java JDK

O JDK deve ser extraído dentro de `tools/java/`.

O Universal Builder possui caminhos específicos para duas versões:

**JDK 8:**

```text
tools/
└── java/
    └── jdk-8/
        ├── bin/
        │   ├── java
        │   ├── javac
        │   └── keytool
        └── lib/
```

**JDK 21:**

```text
tools/
└── java/
    ├── bin/
    │   ├── java
    │   ├── javac
    │   └── keytool
    └── lib/
```

Downloads oficiais:

https://adoptium.net/temurin/releases/

A descoberta automática utiliza as seguintes regras:

- AGP até 6: seleciona JDK 8.
- AGP 7: não possui JDK compatível implementado.
- AGP 8 ou superior: seleciona JDK 21 quando Gradle 8.5 ou superior está disponível.
- Sem AGP identificado, utiliza a versão do Gradle para escolher o JDK.
- Sem informações suficientes, prioriza JDK 8.

Essas regras são as implementadas atualmente, não uma matriz universal de compatibilidade Android.

### 5.3 Gradle

Página oficial:

https://gradle.org/releases/

Baixe a distribuição Gradle necessária e extraia dentro de:

```text
tools/gradle/
```

Exemplo:

```text
tools/
└── gradle/
    ├── gradle-2.13/
    │   └── bin/
    │       └── gradle
    │
    └── gradle-8.5/
        └── bin/
            └── gradle
```

O Builder procura o executável:

```text
tools/gradle/NOME_DA_VERSAO/bin/gradle
```

Quando o projeto possui `gradle-wrapper.properties`, o Builder procura a versão declarada no Wrapper.

Quando não existe uma versão exigida identificável, seleciona a maior versão interna que conseguir executar com os JDKs disponíveis.

O cache do Gradle fica em:

```text
tools/gradle-user-home/
```

O adaptador Android Gradle utiliza esse diretório como `GRADLE_USER_HOME`.

## 6. Comandos disponíveis

### Ajuda

```bash
./builder.sh help
```

### Diagnóstico

```bash
./builder.sh doctor
```

### Listar projetos

```bash
./builder.sh list
```

Lista os diretórios diretamente dentro de `projects/`.

### Clonar um projeto

```bash
./builder.sh clone URL
```

Exemplo:

```bash
./builder.sh clone https://github.com/usuario/projeto.git
```

Também é possível escolher o nome da pasta:

```bash
./builder.sh clone https://github.com/usuario/projeto.git MeuProjeto
```

Os projetos são clonados dentro de `projects/`.

### Inicializar um projeto

```bash
./builder.sh init CAMINHO --profile PERFIL
```

Exemplo:

```bash
./builder.sh init projects/MeuProjeto --profile android-native
```

O comando copia o modelo de configuração do perfil para `builder.conf`.

### Analisar requisitos

```bash
./builder.sh requirements CAMINHO
```

Executa a análise do projeto, a detecção de versões e, para Android, a descoberta das ferramentas internas.

### Verificar dependências

```bash
./builder.sh check CAMINHO
```

Executa o verificador correspondente ao perfil configurado.

### Compilar

```bash
./builder.sh build CAMINHO
```

Verifica as dependências e executa o adaptador especializado ou o comando `BUILD_COMMAND`.

### Limpar saídas

```bash
./builder.sh clean CAMINHO
```

Solicita confirmação e remove a pasta de saída correspondente ao projeto dentro de `output/`.

A limpeza não remove os arquivos-fonte do projeto.

## 7. Assistente interativo

O Universal Builder possui um assistente para preparar projetos automaticamente.

Execute:

```bash
./builder.sh wizard
```

O assistente:

1. Solicita a URL do repositório Git.
2. Clona o projeto dentro de `projects/`.
3. Analisa os requisitos e as versões.
4. Tenta identificar o perfil.
5. Permite confirmar ou escolher outro perfil.
6. Cria `builder.conf`.
7. Identifica comandos de compilação conhecidos ou solicita um comando manual.
8. Verifica os requisitos.
9. Pergunta se deseja compilar imediatamente.

Se a compilação for adiada, o projeto permanece em `projects/`.

Se ocorrer uma falha depois que o assistente criar o clone, ele tenta remover somente a pasta criada por aquela execução.

As ferramentas precisam estar previamente organizadas em `tools/`.

## 8. Configuração dos projetos

Cada projeto utiliza um arquivo:

```text
builder.conf
```

Esse arquivo define o perfil e o comando de compilação.

Exemplo para C++:

```bash
BUILDER_PROFILE="cpp"
BUILD_COMMAND="cmake -S . -B build && cmake --build build -j$(nproc)"
```

Exemplo para Java:

```bash
BUILDER_PROFILE="java"
JAVA_HOME=""
BUILD_COMMAND="mvn package"
```

Exemplo para Python:

```bash
BUILDER_PROFILE="python"
BUILD_COMMAND="python3 -m build"
```

Exemplo para Linux:

```bash
BUILDER_PROFILE="linux"
BUILD_COMMAND="make"
```

Exemplo para Android:

```bash
BUILDER_PROFILE="android-native"

# Sobrescritas opcionais:
# ANDROID_SDK_ROOT=""
# ANDROID_NDK_HOME=""
# ANDROID_PLATFORM=""
# ANDROID_BUILD_TOOLS_VERSION=""
# JAVA_HOME=""

BUILD_COMMAND=""
```

O Builder também carrega, quando existente:

```text
builder.local.conf
```

Esse arquivo é carregado depois de `builder.conf`, permitindo sobrescrever configurações localmente.

Ele está incluído no `.gitignore`.

**Atenção:** os arquivos de configuração são carregados como scripts Bash. Utilize apenas configurações confiáveis.

## 9. Funcionamento da compilação Android

O perfil Android Native possui dois adaptadores especializados.

### 9.1 Android Gradle

O adaptador:

1. Descobre as ferramentas internas.
2. Seleciona SDK, plataforma, Build Tools, JDK e Gradle.
3. Configura o ambiente interno.
4. Executa `assembleDebug`.
5. Localiza os APKs produzidos.
6. Executa `zipalign`.
7. Assina os APKs com `apksigner`.
8. Verifica a assinatura e o alinhamento.
9. Copia os APKs finais para `output/NOME_DO_PROJETO/`.

A assinatura utiliza os esquemas v1 e v2.

Embora a compilação Gradle utilize `assembleDebug`, o adaptador assina o APK resultante com a chave geral de release.

### 9.2 Android NDK legado

O adaptador legado trabalha com projetos que possuem `AndroidManifest.xml` e utilizam a estrutura tradicional Android.

Etapas:

1. Lê os metadados do manifesto.
2. Identifica pacote, versão mínima e versão alvo.
3. Processa recursos com `aapt`.
4. Gera `R.java`.
5. Compila os arquivos Java com `javac`.
6. Gera `classes.dex` com `dx`.
7. Compila bibliotecas nativas quando encontra `Android.mk`.
8. Monta o APK.
9. Executa alinhamento e assinatura.
10. Verifica a assinatura.
11. Copia o APK final para `output/`.

O NDK é utilizado para compilar bibliotecas nativas quando o projeto possui `Android.mk`.

### 9.3 Sistemas Android ainda sem adaptador

O detector também reconhece:

- CMake Android.
- Android Java legado sem Gradle ou NDK-build.

Entretanto, o próprio Builder informa que ainda não possui adaptadores especializados para esses dois casos.

Não confunda detecção do sistema de build com suporte automático à compilação.

## 10. Perfis e dependências

### Android Native

O verificador examina:

- Android SDK.
- Android Platform.
- JDK.
- Gradle, quando o projeto utiliza Gradle.
- Android Gradle Plugin.
- Build Tools.
- `zipalign`.
- `apksigner`.
- `aapt` e `dx` para o sistema legado.
- NDK quando identifica código nativo.

### C++

Verifica:

- CMake.
- Make.
- G++.

Comando padrão:

```bash
cmake -S . -B build && cmake --build build -j$(nproc)
```

### Java

Verifica:

- Java.
- Maven quando existe `pom.xml`.

Comando padrão:

```bash
mvn package
```

### Python

Verifica:

- Python 3.
- pip3.

Comando padrão:

```bash
python3 -m build
```

O pacote Python `build` precisa estar disponível no ambiente utilizado.

### Linux

Verifica:

- Make.
- GCC.

Comando padrão:

```bash
make
```

Os perfis C++, Java, Python e Linux utilizam comandos externos disponíveis no ambiente. Não possuem adaptadores especializados próprios nesta versão.

## 11. Saída dos projetos

Os arquivos gerados são organizados em:

```text
output/
└── NOME_DO_PROJETO/
```

O Builder coleta automaticamente os seguintes formatos no modo de compilação manual:

- APK
- AAB
- EXE
- AppImage
- DEB
- RPM
- JAR
- ZIP
- TAR.GZ
- TAR.XZ

Os adaptadores Android especializados gravam seus APKs diretamente no diretório de saída do projeto.

## 12. Assinatura Android

As chaves utilizadas pelos adaptadores ficam em:

```text
tools/
└── keys/
    ├── debug.keystore
    ├── release-passwords.conf
    └── universal-builder-release.jks
```

O keystore geral utiliza o alias:

```text
universal-builder
```

As senhas são lidas de:

```text
tools/keys/release-passwords.conf
```

O arquivo contém as variáveis utilizadas pelos adaptadores de assinatura.

Não coloque senhas diretamente no código dos adaptadores.

**Aviso de segurança:** publicar um keystore de release junto com o arquivo que contém suas senhas permite que terceiros obtenham acesso à chave de assinatura. Essa decisão compromete a exclusividade da chave e pode permitir a assinatura de aplicativos como se fossem produzidos pelo proprietário original. O repositório deve ser tratado como público e a chave não deve ser considerada secreta.

## 13. Limitações conhecidas

Esta versão possui as seguintes limitações:

- Não existe instalador automático de ferramentas.
- O diretório `installers/` está vazio.
- O arquivo `dependencies.txt` do Android Native não contém dependências concretas.
- CMake Android ainda não possui adaptador especializado.
- Android Java legado ainda não possui adaptador especializado.
- AGP 7 não possui JDK 11 interno disponível para descoberta automática.
- O adaptador Android Gradle utiliza Build Tools 28.0.3 especificamente para assinatura.
- O adaptador Android legado utiliza ferramentas tradicionais como `aapt`, `dx`, `zipalign` e `apksigner`.
- O adaptador Android legado exige NDK localizado mesmo quando não existe código nativo.
- Os perfis C++, Java, Python e Linux dependem das ferramentas disponíveis no ambiente.
- Os comandos de compilação são executados com as permissões do usuário, sem sandbox.
- A descoberta automática não garante compatibilidade com todos os projetos existentes.

O Universal Builder é um orquestrador de compilação configurável, não um compilador universal capaz de compilar qualquer projeto sem preparação.

## 14. Segurança

Antes de compilar projetos de terceiros:

- Revise `builder.conf`.
- Revise `builder.local.conf`.
- Confira o conteúdo de `BUILD_COMMAND`.
- Verifique os scripts de compilação do projeto.
- Não execute projetos desconhecidos sem analisar seu conteúdo.

O Builder não executa os projetos em ambiente isolado.
