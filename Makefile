.PHONY: help run batch batch-dry add-list add-list-dry

help:
	@echo "Targets:"
	@echo "  make run        - rebuild videos.list from curl-list.txt and start download"
	@echo "  make batch      - run download from current videos.list (without rebuild)"
	@echo "  make batch-dry  - validate videos.list without downloading"
	@echo "  make add-list   - rebuild videos.list from curl-list.txt"
	@echo "  make add-list-dry - parse curl-list.txt and print result (no write)"
	@echo ""
	@echo "Quick start: cp .env.example .env"

run:
	./add_job_from_curl.sh --from-list curl-list.txt --list videos.list --replace
	./batch_download.sh

batch:
	./batch_download.sh

batch-dry:
	./batch_download.sh --dry-run

add-list:
	./add_job_from_curl.sh --from-list curl-list.txt --list videos.list --replace

add-list-dry:
	./add_job_from_curl.sh --from-list curl-list.txt --print-only
