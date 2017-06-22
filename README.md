# jats2tex
[![Build Status](https://travis-ci.org/beijaflor-io/jats2tex.svg?branch=master)](https://travis-ci.org/beijaflor-io/jats2tex)
[![AppVeyor Build status](https://ci.appveyor.com/api/projects/status/dgixgy1ep3fp9mlq?svg=true)](https://ci.appveyor.com/project/yamadapc/jats2tex)
- - -
**jats2tex** converte JATS-XML para LaTeX.

![](/04.jpg)

## Instalação
### De um pacote binário (recomendado)
https://github.com/beijaflor-io/jats2tex/releases/

## Uso básico, convertendo JATS-XML para LaTeX
![](/docs/gifs/jats2tex-uso-basico.gif)

## Comando `jats2tex`
```
jats2tex - Customizable JATS to LaTeX Conversion

Usage: jats2tex (version | upgrade | [-o|--output OUTPUT_FILE]
                [-t|--template TEMPLATE_FILE] [-w|--max-width MAX_COLUMN_WIDTH]
                INPUT_FILE)
  Convert JATS-XML INPUT_FILE to LaTeX OUTPUT_FILE

Available options:
  -o,--output OUTPUT_FILE  LaTeX Output File
  -t,--template TEMPLATE_FILE
                           YAML/JSON Template File
  -w,--max-width MAX_COLUMN_WIDTH
                           Maximum Column Width 80 by default, set to 0 to
                           disable
  INPUT_FILE               XML Input File
  -h,--help                Show this help text

Available commands:
  version                  Print the version
  upgrade                  Upgrade jats2tex

```

### Exemplos
**Converter arquivo teste.xml e imprimir resultado no terminal**
```
jats2tex ./teste.xml
```

**Converter arquivo teste.xml e imprimir resultado em teste.tex**
```
jats2tex ./teste.xml --output ./teste.tex
```

**Limitar o número de colunas em 100 caracteres**
```
jats2tex ./teste.xml --max-width 100
```

**Desativar "text wrapping"**
```
jats2tex ./teste.xml --max-width 0
```

## Customizando a saída
Para controlar o formato da saída, usamos um arquivo em formato YAML descrevendo
o mapa de tags para TeX.

**O template é especificado para o comando usando a flag `-t`:**
```
jats2tex ./teste.xml -t ./meu-template.yaml
```

O arquivo mapeia `{nome-da-tag}: "\latexcorrespondente"` e permite a
interpolação de _variáveis de contexto_ e _expressões de Haskell_ para a
conversão de nódulos XML para LaTeX.

### Sintaxe
#### Variáveis de contexto disponíveis
- `@@children` Interpola todos os filhos da tag atual convertidos como LaTeX
- `@@heads` Interpola todos os filhos da tag atual marcados como 'head'
- `@@bodies` Interpola todos os filhos da tag atual marcados como 'content'

#### Definindo tags
Definimos tags com:
```yaml
conteudoxml: |
  \conteudolatex{@@children e outras varíaveis ou interpolações}

# ou

conteudoxml-com-head:
  # Conteúdo '@@bodies' dessa correspondência
  # (equivale a `conteudoxml-com-head: "\asdfasdf{}"`)
  content: |
    \asdfadsf{}
  # Conteúdo '@@heads' dessa correspondência
  head: |
    \conteudolatex{@@children e outras varíaveis ou interpolações}
```

##### Exemplo 1: Mapa simples de tag para saída
O template `default.yaml` incluso no `jats2tex` define o seguinte mapa para a
tag `b`, que indica texto em negrito:

```yaml
b: |
  \textbf{@@children}
```

Dado esse template e um arquivo XML como:
```xml
<b>Olá mundo</b>
```

O programa irá produzir:
```latex
% Generated by jats2tex@x.x.x.x
\textbf{Olá mundo}
```

##### Exemplo 2: Usando `@@heads` e `@@bodies` para controlar a estrutura da saída
Dado um XML:
```xml
<?xml version="1.0" encoding="ISO-8859-1"?>
<article xmlns:mml="http://www.w3.org/1998/Math/MathML" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<front>
  <article-meta>
    <title-group>
      <article-title xml:lang="en">My Title</article-title>
    </title-group>
  </article-meta>
</front>
<body>Meu texto aqui</body>
</article>
```

Queremos a saída:
```tex
\documentclass{article}
\begin{document}
\title{My Title}
\maketitle
Meu texto aqui
\end{document}
```

Para isso podemos usaríamos o template:
```yaml
article:
  head: |
    \documentclass{article}
    \begin{document}
    @@heads
    \maketitle
    @@bodies
    \end{document}

article-title:
  head: |
    \title{@@children}
```
Como `article-title` tem sua saída marcada como `head`, seu conteúdo é
interpolado como `@@heads`, enquanto o corpo do texto por padrão simplesmente é
interpolado como visto, se não estiver mapeado por `@@bodies`.

#### Interpolação de haskell
Além das diretrizes acima, o `jats2tex` incluí em seus templates suporte para a
interpolação de expressões arbitrárias na linguagem de programação Haskell, que
são executadas em runtime. Outras linguagens ou sintaxes podem ser exploradas no
futuro.

A sintaxe é:
```yaml
p: |
  \saida{@@(
    findChildren "font"
  )@@}
```

O motivo disso é que em alguns casos a conversão deve executar regras complexas.
Uma biblioteca de "helpers" está sendo desenvolvida para ser inclusa com o
pacote. `findChildren n` por exemplo, encontra os filhos do elemento atual cujas
tags tem o nome `n` as converte e interpola no local indicado.

##### Exemplo 3: Intercalando "\and" entre os autores de um artigo
Template:
```yaml
name: |
  @@(
  findChildren "surname"
  )@@, @@(
  findChildren "given-names"
  )@@

contrib-group:
  head: |
    \author{@@(
        intercalate (raw "\\and ") =<< elements context
      )@@}
```
Entrada:
```xml
<contrib-group>
  <contrib contrib-type="author">
    <name>
      <surname><![CDATA[Quiroga Selez]]></surname>
      <given-names><![CDATA[Gabriela]]></given-names>
    </name>
  </contrib>
  <contrib contrib-type="author">
    <name>
      <surname><![CDATA[Giménez Turba]]></surname>
      <given-names><![CDATA[Alberto]]></given-names>
    </name>
  </contrib>
</contrib-group>
```
Saída:
```latex
\author{Quiroga Selez, Gabriela
\and Giménez Turba, Alberto
}
```

- - -

## Formato dos templates
Em aberto, os templates usados pelo Jats2tex terão um formato de fácil escrita por
humanos e computadores, um mapa de chaves e valores com suporte a nesting
(por exemplo, `conf`, `yml`, `json`, `ini`).

## Implementação
A partir do formato do template com suporte a customização da renderização de
elementos e atributos em contextos diferentes, um tipo intermediário e um
renderizador estilo "Visitor", o programa lerá e executará um parser XML no
input, conseguindo um tipo 'Artigo' - ou falhando com entrada inválida.

O programa usa o template para configurar um renderizador desse tipo para
LaTeX, usando uma linguagem monádica exposta pelo pacote `HaTeX`.

## Tecnologia
A tecnologia usada para elaborar a solução será a linguagem de programação
Haskell e pacotes embutidos para:

- A construção de parsers
- Parsing de arquivos XML
- Renderização de LaTeX/ConText válido

## Metodologia
O trabalho será feito usando a metodologia Agile de desenvolvimento de
Software. Assim o trabalho será dividido em metas curtas (Sprints) com o
período de uma semana.

O projeto será disponibilizado online via GitHub, escrito usando código
aberto. Ao final de cada semana, uma versão será empacotada e publicada com as
melhorias executadas.

## Interfaces de Uso
### Web
Um endpoint `POST` receberá dados em formato JATS-XML e dará o texto convertido
para LaTeX como resposta. Opcionalmente, recebe também o arquivo/texto de um
template.

### CLI
Opções serão expostas pela linha de comando usando o `optparse-applicative`, o
comando recebe um template e uma entrada JATS-XML e escreve o resultado para a
saída padrão.
