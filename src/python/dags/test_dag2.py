from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.dummy import DummyOperator
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

# Default arguments for the DAG
default_args = {
    'owner': 'data_team',
    'depends_on_past': False,
    'start_date': datetime(2024, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5)
}

# Define the DAG
dag = DAG(
    'simple_data_pipeline',
    default_args=default_args,
    description='A simple data pipeline DAG',
    schedule_interval=timedelta(days=1),  # Run daily
    catchup=False,
    tags=['example', 'data']
)

# Python function for data processing task
def process_data():
    """Simple data processing function"""
    print("Processing data...")
    # Simulate some data processing
    import time
    time.sleep(2)
    print("Data processing completed!")
    return "Data processed successfully"

# Define tasks
start_task = DummyOperator(
    task_id='start',
    dag=dag
)

extract_data = BashOperator(
    task_id='extract_data',
    bash_command='echo "Extracting data from source..."',
    dag=dag
)

transform_data = PythonOperator(
    task_id='transform_data',
    python_callable=process_data,
    dag=dag
)

validate_data = BashOperator(
    task_id='validate_data',
    bash_command='echo "Validating transformed data..." && sleep 1 && echo "Validation passed!"',
    dag=dag
)

load_data = BashOperator(
    task_id='load_data',
    bash_command='echo "Loading data to destination..." && sleep 2 && echo "Data loaded successfully!"',
    dag=dag
)

send_notification = PythonOperator(
    task_id='send_notification',
    python_callable=lambda: print("Pipeline completed! Notification sent."),
    dag=dag
)

end_task = DummyOperator(
    task_id='end',
    dag=dag
)

# Define task dependencies
start_task >> extract_data >> transform_data >> validate_data >> load_data >> send_notification >> end_task