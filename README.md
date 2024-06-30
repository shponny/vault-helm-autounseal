# Деплой Vault + автораспечатывание + бэкапы

Скрипт развертывает из официального Helm-чарта кластер Vault в один неймспейс в кластере Kubernetes/OpenShift, настраивает его автораспечатывание (Shamir + Argo Events + Kubernetes Job) и бэкапы в S3 (CronJob).

## Prerequisites
- Кластер Kubernetes / OpenShift, куда, собственно, и будет устанавливаться кластер Vault.
- helm
- kubectl (v1.27, т.к. с версией поновее вылазит [ошибка](https://issues.redhat.com/browse/OCPBUGS-31639) при создании CronJob)
- jq
- yq ([by kislyuk](https://github.com/kislyuk/yq) - jq wrapper)
- s3cmd (для восстановления из бэкапа)

## Installation
1. `git clone`
2. ["Залогиньтесь"](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/) в свой кластер
    - или через `~/.kube/config`;
    - или через `kubectl config ...`
    - или, если кластер OpenShift и установлен `oc` - через `oc login`
3. Если есть SSL-сертификат для Vault, добавьте его в `tls.crt` вместе с ключом в `tls.key` (но необязательно)
4. Заполните все необходимые данные в `vault.yaml` - это наш Values для Helm-чарта Vault - подробнее по заполнению - [в документации](https://developer.hashicorp.com/vault/docs/platform/k8s/helm/configuration).    
Обратите внимание, что при отсутствии прав админа в кластере не удастся поставить Injector.
5. `chmod +x setup.sh`
6. `./setup.sh`

**Важно!** В процессе установки в текущей директории появится `vault.json` - внутри будут **ключи распечатывания**.

## Shamir-"Autounseal" с помощью Argo Events    
    
    Все необходимые файлы лежат в директории argo-events.
---
1. Решаем, где поставить Argo Events - непосредственно в кластере K8s/OpenShift, где живёт Vault, или в отдельном, если, например, в основном нет прав cluster-admin.    
2. Устанавливаем Argo Events - https://argoproj.github.io/argo-events/installation/
3. **Если Argo Events и Vault в _одном кластере_:** (UNFINISHED - NEEDS TESTING)
  - Выбираем тот же неймспейс, где установлен Vault
  - Создаём EventBus - `kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-events/stable/examples/eventbus/native.yaml`
  - Создаём Event Source из файла `argo-events/event-source-k8s.yaml`, предварительно внутри поменяв неймспейс и в фильтрах название Helm-релиза.    
  `kubectl apply -f argo-events/event-source-k8s.yaml`
  - Создаём ServiceAccount, с помощью которого и будет запускаться Trigger - `kubectl create serviceaccount argo-sa`
  - Создаём Role для ServiceAccount'a с возможностью Create/Update/List/Watch Pod'ов - `kubectl apply -f argo-events/role-pod-list-create.yml`
  - Создаём Role Binding для созданных SA и роли - `kubectl create rolebinding argo-sa-role-binding --role=argo-events-pod-list-create-role --serviceaccount=your-namespace:argo-sa`
  - Создаём Secret из файла `vault.json` с ключами распечатывания - `kubectl create secret generic vault-keys --from-file=vault.json`
  - Создаём Sensor из файла `argo-events/sensor-k8s.yaml` - предварительно просмотрите его конфигурацию!!!    
    `kubectl apply -f argo-events/sensor-k8s.yaml`


4. **Если Argo Events и Vault в _разных кластерах_:**
  - Во "внешнем" кластере создаём нужный неймспейс и его используем (например, `vault-unseal`)
  - Создаём там EventBus - `kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-events/stable/examples/eventbus/native.yaml`
  - Создаём Event Source из файла `argo-events/event-source-webhook.yaml`. Pod, созданный EventSource'ом, будет слушать внутри кластера по порту `12000`, эндпоинт - `/vault-sealed`.
  - Т.к. по умолчанию EventSource "слушает" *внутри* кластера, а вебхуки "прилетают" снаружи, то делаем или Ingress, или NodePort/LoadBalancer. Пример Ingress'а - в файле `argo-events/ingress.yml`.    
      
    **_НИЖЕ - ДЕЙСТВИЯ В КЛАСТЕРЕ С Vault!_**
  - Создаём ServiceAccount, с помощью которого будем "лазить" в кластер - `kubectl create serviceaccount argo-sa`
  - Создаём Role для ServiceAccount'a с возможностью List/Watch/Exec Pod'ов - `kubectl apply -f argo-events/role-pod-list-exec.yml`
  - Создаём Role Binding для созданных SA и роли - `kubectl create rolebinding argo-sa-role-binding --role=argo-events-pod-list-exec-role --serviceaccount=your-namespace:argo-sa`    
  - После создания ServiceAccount'a лезем в автоматически созданный Secret, дефолтное имя которого будет `argo-sa-token-xxxxx`, и оттуда тянем `token`. Этот токен записываем в файл `argo-events/config` - с помощью этого `kubeconfig`-a Pod во "внешнем" кластере будет лезть в этот кластер и распечатывать запечатанные поды через `kubectl exec`.    
  В этот же `config` запишем адрес API (его можно достать с помощью `kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'`)
  - Нам нужен сервис, который должен высылать webhook в Argo Events о запечатанных нодах. Для этого задействуем метрики, Prometheus и AlertManager. Поэтому:
    - В установленном Vault Helm Release должны быть активированы метрики - в `vault.yaml` в конфигах (обычно в `ha` или в `standalone`) см. `listener "tcp" -> telemetry` и отдельно `telemetry`.
    - В `prometheus/prometheus.yml` прописываем namespace и Vault Helm Release name.
    - В `alertmanager/alertmanager.yml` прописываем адрес, на котором слушает Argo Events EventSource.
    - Создаём Prometheus и Alertmanager:    
    `kubectl create -f prometheus/`    
    `kubectl create -f alertmanager/`   

    **_ДАЛЕЕ - ДЕЙСТВИЯ ВО "ВНЕШНЕМ" КЛАСТЕРЕ С Argo Events!_**
  - Здесь тоже делаем ServiceAccount - тут он для того, чтобы Trigger смог создать Pod, который и будет лезть в кластер с Vault и распечатывать там ноду.    
  `kubectl create serviceaccount argo-sa`
  - Создаём Role для ServiceAccount'a с возможностью Create/Update/List/Watch Pod'ов - `kubectl apply -f argo-events/role-pod-list-create.yml`
  - Создаём Role Binding для созданных SA и роли - `kubectl create rolebinding argo-sa-role-binding --role=argo-events-pod-list-create-role --serviceaccount=your-namespace:argo-sa`
  - Создаём Secret из файла `vault.json` с ключами распечатывания - `kubectl create secret generic vault-keys --from-file=vault.json`
  - Также необходимо создать Secret с `kubeconfig`-ом для подключения к кластеру с Vault, который использует свежесозданный ServiceAccount. Для этого используем ранее нами заполненный файл `argo-events/config`.    
  `kubectl create secret generic kubeconfig-vault --from-file=argo-events/config`
  - Теперь можно создавать Sensor - `kubectl apply -f argo-events/sensor-webhook.yaml`


## Backup Cron-job
Для настройки бэкапов будут необходимы:
- Адрес S3-сервера в формате `s3.xxx.xxx`
- Access Key ID
- Secret Access Key
- Bucket name - этот bucket должен быть создан заранее.    

Версионирование/lifecycle policy - со стороны S3.

## Restore from Backup
`./restore.sh`, предварительно залогинившись в кластер (читать в [Installation](#installation)).    
Процесс восстановления следующий:
1. **!!! УДАЛЯЕТСЯ** "старый" кластер вместе с PVC.
2. На его месте создаётся новый с нуля.
3. Генерируется новый файл с Shamir-ключами и рут-токеном, кластер распечатывается.
4. Пользователь выбирает, откуда доставать бэкап:
    - вариант 1 - используя S3-креды (`Access Key ID, Secret Access Key, server hostname, bucket name`) **из CronJob** (дефолтный вариант)
    - вариант 2 - введя руками "новые"
5. Выводится список сделанных бэкапов (список объектов из S3-бакета) - пользователь выбирает, из какого бэкапа восстанавливаться.
6. Генерируется временная pre-signed ссылка на выбранный объект.
7. Внутри пода в кластере - бэкап скачивается и происходит восстановление (предварительно залогинившись токеном из только что созданного файла с ключами).
8. Рестарт кластера
9. Если настроено автораспечатывание с помощью Argo Events - новый `vault.json` нужно записать в соответствующий Secret `vault-keys`.
10. ?????
11. PROFIT!