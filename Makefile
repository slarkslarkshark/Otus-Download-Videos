.PHONY: help run batch batch-dry add-list add-list-dry

help:
	@echo "Targets:"
	@echo "  make run        - rebuild videos.list from CURLs file in config.yaml and start download"
	@echo "  make batch      - run download from current videos.list (without rebuild)"
	@echo "  make batch-dry  - validate videos.list without downloading"
	@echo "  make add-list   - rebuild videos.list from CURLs file in config.yaml"
	@echo "  make add-list-dry - parse CURLs file from config.yaml and print result (no write)"
	@echo ""
	@echo "Quick start: edit config.yaml if needed, then run make run"

run:
	./add_job_from_curl.sh --replace
	./batch_download.sh

batch:
	./batch_download.sh

batch-dry:
	./batch_download.sh --dry-run

add-list:
	./add_job_from_curl.sh --replace

add-list-dry:
	./add_job_from_curl.sh --print-only
