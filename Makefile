.PHONY: help run batch batch-dry download decrypt discover

help:
	@echo "Targets:"
	@echo "  make run        - main one-command workflow (batch mode)"
	@echo "  make batch      - run batch download from videos.list"
	@echo "  make batch-dry  - validate videos.list without downloading"
	@echo "  make discover   - helper to find m3u8 from one ts URL"
	@echo "  make download   - legacy single-video download workflow"
	@echo "  make decrypt    - legacy local decrypt workflow"
	@echo ""
	@echo "Quick start: cp .env.example .env && cp videos.list.example videos.list"

run:
	./batch_download.sh

batch:
	./batch_download.sh

batch-dry:
	./batch_download.sh --dry-run

discover:
	./find_m3u8.sh --help

download:
	./download.sh

decrypt:
	./decrypt.sh
