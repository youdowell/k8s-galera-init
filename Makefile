NAME = youdowell/k8s-galera-init
VERSION = $(shell sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"(.+)".*/\1/p' package.json)

.PHONY: all build tag-latest release

all: build

version:
	@echo ${VERSION}

build:
	docker build -t $(NAME):$(VERSION) --rm ./image

test:
	tests/mysql-tests.sh

tag-latest:
	docker tag -f $(NAME):$(VERSION) $(NAME):latest

release: test tag-latest
	@if ! docker images $(NAME) | awk '{ print $$2 }' | grep -q -F $(VERSION); then echo "$(NAME) version $(VERSION) is not yet built. Please run 'make build'"; false; fi
	docker push $(NAME)
	@echo "*** Don't forget to create a tag. git tag v$(VERSION) -m "$(VERSION)" && git push origin v$(VERSION)"
