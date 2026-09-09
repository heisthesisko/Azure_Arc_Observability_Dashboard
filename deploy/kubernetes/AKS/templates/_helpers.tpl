{{- define "arc-dashboard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "arc-dashboard.fullname" -}}
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

{{- define "arc-dashboard.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "arc-dashboard.labels" -}}
helm.sh/chart: {{ include "arc-dashboard.chart" . }}
{{ include "arc-dashboard.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{- define "arc-dashboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "arc-dashboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "arc-dashboard.serviceAccountName" -}}
{{- default (include "arc-dashboard.fullname" .) .Values.serviceAccount.name }}
{{- end }}

{{- define "arc-dashboard.pvcName" -}}
{{- default (printf "%s-data" (include "arc-dashboard.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{- define "arc-dashboard.dashboardImage" -}}
{{- if .Values.image.digest -}}
{{ printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end -}}
{{- end }}

{{- define "arc-dashboard.proxyImage" -}}
{{- if .Values.oauth2Proxy.image.digest -}}
{{ printf "%s@%s" .Values.oauth2Proxy.image.repository .Values.oauth2Proxy.image.digest }}
{{- else -}}
{{ printf "%s:%s" .Values.oauth2Proxy.image.repository .Values.oauth2Proxy.image.tag }}
{{- end -}}
{{- end }}
