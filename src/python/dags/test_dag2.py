from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.python import PythonOperator

default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
    'email_on_failure': False,
    'email_on_retry': False,
}


def print_hello():
    """Simple Python function that prints hello"""
    print("Hello world from Airflow!")
    return "Hello world task completed successfully"


def print_date():
    """Print current date and time"""
    current_time = datetime.now()
    print(f"Current time: {current_time}")
    return current_time


with DAG(
        dag_id='hello_world_improved',
        description='Hello World DAG with improvements',
        schedule_interval=timedelta(minutes=10),  # Every 10 minutes for testing
        start_date=datetime(2025, 1, 1),  # More recent start date
        catchup=False,
        tags=['test', 'tutorial', 'hello-world'],
        default_args=default_args,
        max_active_runs=1,  # Prevent overlapping runs
) as dag:
    hello_task = PythonOperator(
        task_id='say_hello',
        python_callable=print_hello,
        doc_md="""
        ## Hello Task
        This task prints 'Hello world!' to the logs.
        """
    )

    date_task = PythonOperator(
        task_id='print_current_date',
        python_callable=print_date,
        doc_md="""
        ## Date Task  
        This task prints the current date and time.
        """
    )

    # Set task dependencies
    hello_task >> date_task