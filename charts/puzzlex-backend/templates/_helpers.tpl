{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "puzzlex-backend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "puzzlex-backend.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "puzzlex-backend.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "puzzlex-backend.labels" -}}
helm.sh/chart: {{ include "puzzlex-backend.chart" . }}
{{ include "puzzlex-backend.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "puzzlex-backend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "puzzlex-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Service name for a component
*/}}
{{- define "puzzlex-backend.component.fullname" -}}
{{- printf "%s-%s" (include "puzzlex-backend.fullname" .) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels for a component
*/}}
{{- define "puzzlex-backend.component.labels" -}}
helm.sh/chart: {{ include "puzzlex-backend.chart" . }}
{{ include "puzzlex-backend.component.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels for a component
*/}}
{{- define "puzzlex-backend.component.selectorLabels" -}}
app.kubernetes.io/name: {{ include "puzzlex-backend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "puzzlex-backend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "puzzlex-backend.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Merge common env vars with component-specific env vars and extra env vars
Order: commonEnv -> commonEnvExtra -> componentEnv -> extraEnv (later values override earlier ones)
De-duplicates by name, keeping the last occurrence.

Priority (lowest to highest):
1. commonEnv - Base common config (from values.yaml, should not be overridden in env files)
2. commonEnvExtra - Environment-specific common config (from values-{env}.yaml)
3. componentEnv - Component-specific config (e.g., web.env, sidekiq.env)
4. extraEnv - Highest priority component overrides (e.g., web.extraEnv)
*/}}
{{- define "puzzlex-backend.env" -}}
{{- $envMap := dict }}
{{- /* First pass: collect all env vars into a map keyed by name */}}
{{- /* 1. Base commonEnv from values.yaml */}}
{{- if .Values.commonEnv }}
{{- range .Values.commonEnv }}
{{- $_ := set $envMap .name . }}
{{- end }}
{{- end }}
{{- /* 2. Extra common env vars (for environment overrides) */}}
{{- if .Values.commonEnvExtra }}
{{- range .Values.commonEnvExtra }}
{{- $_ := set $envMap .name . }}
{{- end }}
{{- end }}
{{- /* 3. Component-specific env vars */}}
{{- if .componentEnv }}
{{- range .componentEnv }}
{{- $_ := set $envMap .name . }}
{{- end }}
{{- end }}
{{- /* 4. Extra env vars (highest priority) */}}
{{- if .extraEnv }}
{{- range .extraEnv }}
{{- $_ := set $envMap .name . }}
{{- end }}
{{- end }}
{{- /* Second pass: convert map back to list */}}
{{- $envList := list }}
{{- range $name, $env := $envMap }}
{{- $envList = append $envList $env }}
{{- end }}
{{- if $envList }}
{{- toYaml $envList }}
{{- end }}
{{- end -}}
