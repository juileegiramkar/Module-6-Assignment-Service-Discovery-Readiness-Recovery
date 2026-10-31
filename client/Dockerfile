FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app
COPY client.py .

RUN useradd --uid 10001 --no-create-home appuser
USER 10001

# Standard library only, no pip install needed.
ENTRYPOINT ["python", "client.py"]
CMD ["loop"]
