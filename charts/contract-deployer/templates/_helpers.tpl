{{/*
Expand the name of the chart.
*/}}
{{- define "contract-deployer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "contract-deployer.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "contract-deployer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "contract-deployer.labels" -}}
helm.sh/chart: {{ include "contract-deployer.chart" . }}
{{ include "contract-deployer.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "contract-deployer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "contract-deployer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Container environment variables
*/}}
{{- define "contract-deployer.env" -}}
- name: RPC_URL
  value: {{ .Values.network.rpcUrl | quote }}
- name: CHAIN_ID
  value: {{ .Values.network.chainId | quote }}
- name: DRY_RUN
  value: {{ .Values.deployment.dryRun | quote }}
- name: WAIT_FOR_RPC
  value: {{ .Values.deployment.waitForRpc | quote }}
- name: KEEP_ALIVE
  value: {{ .Values.deployment.keepAlive | quote }}
- name: CONTRACTS_OUTPUT_PATH
  value: {{ .Values.output.path | quote }}
- name: PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.name }}
      key: {{ .Values.secrets.privateKeyKey }}
# K8s ConfigMap 配置
- name: K8S_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: CONFIGMAP_NAME
  value: {{ .Values.output.configMapName | default "contract-addresses" | quote }}
# 后端使用的 RPC URL (可选，用于 ConfigMap 中的 BLOCKCHAIN_RPC_URL)
{{- if .Values.network.backendRpcUrl }}
- name: BACKEND_RPC_URL
  value: {{ .Values.network.backendRpcUrl | quote }}
{{- end }}
# ============================================
# 前端环境变量同步配置 (仅 Cloudflare 模式)
# 本地开发使用: cd frontend && npm run env:sync:local
# 参考文档: docs/adr/ADR-075-frontend-env-sync.md
# ============================================
{{- if .Values.frontendSync.enabled }}
- name: FRONTEND_SYNC_TARGET
  value: {{ .Values.frontendSync.target | quote }}
- name: FRONTEND_SYNC_CF_ENV
  value: {{ .Values.frontendSync.cloudflare.env | quote }}
# 要同步的项目列表 (逗号分隔): trading,admin
- name: FRONTEND_SYNC_PROJECTS
  value: {{ .Values.frontendSync.cloudflare.projects | default "trading" | quote }}
- name: FRONTEND_SYNC_GITHUB_REPO
  value: {{ .Values.frontendSync.cloudflare.githubRepo | quote }}
{{- if .Values.frontendSync.github.existingSecret }}
- name: FRONTEND_SYNC_GITHUB_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ .Values.frontendSync.github.existingSecret }}
      key: {{ .Values.frontendSync.github.existingSecretKey | default "pat-dispatch" }}
{{- end }}
{{- end }}
{{- end }}
