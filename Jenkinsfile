pipeline {

    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    environment {
        AWS_REGION = 'us-east-1'
        AWS_ACCOUNT_ID = '874551618373'

        ECR_REGISTRY = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

        HELLO_REPO = 'hello-service'
        PROFILE_REPO = 'profile-service'
        FRONTEND_REPO = 'mern-frontend'

        IMAGE_TAG = "v${BUILD_NUMBER}"
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Verify Source') {
            steps {
                sh '''
                    set -eux

                    echo "Git commit:"
                    git rev-parse HEAD

                    echo
                    echo "Project structure:"
                    find . -maxdepth 3 -type f | sort

                    echo
                    echo "Dockerfiles:"
                    find . -name Dockerfile -print
                '''
            }
        }

        stage('AWS Identity') {
            steps {
                withAWS(
                    credentials: 'aws-ecr-credentials',
                    region: "${AWS_REGION}"
                ) {
                    sh '''
                        set -eux

                        aws sts get-caller-identity

                        echo
                        echo "AWS Region:"
                        aws configure get region || true
                    '''
                }
            }
        }

        stage('ECR Login') {
            steps {
                withAWS(
                    credentials: 'aws-ecr-credentials',
                    region: "${AWS_REGION}"
                ) {
                    sh '''
                        set -eux

                        aws ecr get-login-password \
                            --region "${AWS_REGION}" |
                        docker login \
                            --username AWS \
                            --password-stdin "${ECR_REGISTRY}"
                    '''
                }
            }
        }

        stage('Build Hello Service') {
            steps {
                sh '''
                    set -eux

                    docker build \
                        -t "${ECR_REGISTRY}/${HELLO_REPO}:${IMAGE_TAG}" \
                        -t "${ECR_REGISTRY}/${HELLO_REPO}:latest" \
                        ./backend/helloService
                '''
            }
        }

        stage('Build Profile Service') {
            steps {
                sh '''
                    set -eux

                    docker build \
                        -t "${ECR_REGISTRY}/${PROFILE_REPO}:${IMAGE_TAG}" \
                        -t "${ECR_REGISTRY}/${PROFILE_REPO}:latest" \
                        ./backend/profileService
                '''
            }
        }

        stage('Build Frontend') {
            steps {
                sh '''
                    set -eux

                    docker build \
                        -t "${ECR_REGISTRY}/${FRONTEND_REPO}:${IMAGE_TAG}" \
                        -t "${ECR_REGISTRY}/${FRONTEND_REPO}:latest" \
                        ./frontend
                '''
            }
        }

        stage('Push Images') {
            steps {
                withAWS(
                    credentials: 'aws-ecr-credentials',
                    region: "${AWS_REGION}"
                ) {
                    sh '''
                        set -eux

                        docker push \
                            "${ECR_REGISTRY}/${HELLO_REPO}:${IMAGE_TAG}"

                        docker push \
                            "${ECR_REGISTRY}/${HELLO_REPO}:latest"

                        docker push \
                            "${ECR_REGISTRY}/${PROFILE_REPO}:${IMAGE_TAG}"

                        docker push \
                            "${ECR_REGISTRY}/${PROFILE_REPO}:latest"

                        docker push \
                            "${ECR_REGISTRY}/${FRONTEND_REPO}:${IMAGE_TAG}"

                        docker push \
                            "${ECR_REGISTRY}/${FRONTEND_REPO}:latest"
                    '''
                }
            }
        }

        stage('Verify ECR') {
            steps {
                withAWS(
                    credentials: 'aws-ecr-credentials',
                    region: "${AWS_REGION}"
                ) {
                    sh '''
                        set -eux

                        echo "Hello Service:"
                        aws ecr describe-images \
                            --repository-name "${HELLO_REPO}" \
                            --region "${AWS_REGION}" \
                            --query 'imageDetails[].imageTags' \
                            --output table

                        echo
                        echo "Profile Service:"
                        aws ecr describe-images \
                            --repository-name "${PROFILE_REPO}" \
                            --region "${AWS_REGION}" \
                            --query 'imageDetails[].imageTags' \
                            --output table

                        echo
                        echo "Frontend:"
                        aws ecr describe-images \
                            --repository-name "${FRONTEND_REPO}" \
                            --region "${AWS_REGION}" \
                            --query 'imageDetails[].imageTags' \
                            --output table
                    '''
                }
            }
        }
    }

    post {

        success {
            echo '=============================================='
            echo 'JENKINS CI/CD SUCCESS'
            echo '=============================================='
            echo "Images pushed successfully."
            echo "Build: ${BUILD_NUMBER}"
            echo "Tag: ${IMAGE_TAG}"
        }

        failure {
            echo '=============================================='
            echo 'JENKINS CI/CD FAILED'
            echo '=============================================='
            echo "Build: ${BUILD_NUMBER}"
        }

        always {
            sh '''
                docker logout "${ECR_REGISTRY}" || true
            '''
        }
    }
}
