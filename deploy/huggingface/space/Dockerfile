# Open WebUI as a Hugging Face Space.
#
# Deliberately tiny: HF Spaces builds happen on the Space's own hardware and a
# from-source Open WebUI build (npm ci + vite build + pip install) takes tens of
# minutes and has to fit in the build timeout. Reusing the published image turns
# "deploy my fork" into a 1-2 minute build.
#
# The tag below is rewritten by scripts/deploy-hf-space.sh (--tag); edit it here
# if you deploy by hand.
FROM ghcr.io/open-webui/open-webui:main

# Spaces routes app_port traffic to this port (see README.md frontmatter).
ENV PORT=8080 \
    HOST=0.0.0.0

# Put the database, uploads and vector store on the Space's mountable volume so a
# Storage Bucket attached at /data actually persists them. Without a bucket /data
# is just as ephemeral as the default /app/backend/data — it simply costs nothing
# to be ready for one.
ENV DATA_DIR=/data
RUN mkdir -p /data && chmod 0777 /data

# Optional local models live here too (only useful on CPU Upgrade or bigger).
ENV HF_HOME=/data/cache/huggingface \
    SENTENCE_TRANSFORMERS_HOME=/data/cache/huggingface \
    TIKTOKEN_CACHE_DIR=/data/cache/tiktoken \
    WHISPER_MODEL_DIR=/data/cache/whisper
RUN mkdir -p /data/cache/huggingface /data/cache/tiktoken /data/cache/whisper \
    && chmod -R a+rwX /data/cache
