version=$(shell cat ./package.yaml | kv-formats -i yaml -o json | jq '.version')
tag=$(shell git describe --tags)

build: build-frontend FORCE
	stack build

build-frontend: FORCE
	cd ./jats2tex-web && npm run build

build-manpages: FORCE
	for i in ./docs/man/*.md; do \
		echo $$i; \
		echo `dirname $$i`; \
		pandoc -s $$i -t man -o `dirname $$i`/`basename $$i .md`.man; \
	done

build-linux: build-frontend FORCE
	stack docker pull
	stack build --docker # --ghc-options="-optc-Os -optl-static -fPIC"

package: FORCE
	./bin/stack-fpm jats2tex $(version)

full-release: FORCE
	make release
	make deploy

deploy: FORCE
	make build-image
	heroku container:push

build-image: FORCE
	rm -rf dockerworkspace
	mkdir dockerworkspace
	cp ./Dockerfile ./dockerworkspace/Dockerfile
	mkdir -p ./dockerworkspace/.stack-fpm
	cp -r ./.stack-fpm/linux ./dockerworkspace/.stack-fpm/linux
	cd dockerworkspace && docker build -t jats2tex:$(tag) .
	rm -rf dockerworkspace

release: FORCE
	echo $(tag)
	make build-linux
	make package
	github-release release -u beijaflor-io -r jats2tex -t $(tag) -n $(tag)
	make upload

upload: FORCE
	for i in dist/*$(version)*; do \
		echo $$i; \
		github-release upload -u beijaflor-io -r jats2tex -t $(tag) -n $$i -f $$i -l $$i; \
	done

build-pdf: FORCE
	pandoc ./README.md -o ./jats2tex.pdf

build-osx: build-frontend FORCE
	stack build --extra-lib-dirs=/usr/local/opt/icu4c/lib --extra-include-dirs=/usr/local/opt/icu4c/include

example: FORCE
	stack build # --executable-profiling --library-profiling
	rm ./example-output.*
	stack exec jats2tex ./examples/S0250-54602016000400001.xml -- --output ./example-output.tex
	# ./latexindent.sh ./example-output.tex > ./example-output.fmt.tex
	# mv ./example-output.fmt.tex ./example-output.tex
	latex ./example-output.tex

FORCE:
