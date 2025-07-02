FROM apache/airflow:3.0.2-python3.12

RUN pip install uv
WORKDIR /opt/airflow
COPY pyproject.toml uv.lock ./

RUN uv sync
COPY src/python/dags ./dags
COPY src/python/plugins ./plugins