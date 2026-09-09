{{- define "arc-dashboard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "arc-dashboard.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "arc-dashboard.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "arc-dashboard.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/name: {{ include "arc-dashboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: arc-dashboard
{{- end }}

{{- define "arc-dashboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "arc-dashboard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "arc-dashboard.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "arc-dashboard.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "arc-dashboard.pvcName" -}}
{{- default (include "arc-dashboard.fullname" .) .Values.persistence.existingClaim }}
{{- end }}

{{- define "arc-dashboard.image" -}}
{{- if .digest }}
{{- printf "%s@%s" .repository .digest }}
{{- else }}
{{- printf "%s:%s" .repository (.tag | default "latest") }}
{{- end }}
{{- end }}

{{- define "arc-dashboard.validate" -}}
{{- if not .Values.persistence.enabled }}
{{- fail "persistence.enabled must remain true; Azure Arc Observability Dashboard requires persistent state" }}
{{- end }}
{{- if not .Values.route.enabled }}
{{- fail "route.enabled must remain true for the supported OpenShift deployment" }}
{{- end }}
{{- $_ := required "route.host is required" .Values.route.host }}
{{- $_ := required "azureIdentity.tenantId is required" .Values.azureIdentity.tenantId }}
{{- $_ := required "azureIdentity.clientId is required" .Values.azureIdentity.clientId }}
{{- $_ := required "azureIdentity.subscriptionId is required" .Values.azureIdentity.subscriptionId }}
{{- $_ := required "oauth2Proxy.clientId is required" .Values.oauth2Proxy.clientId }}
{{- $_ := required "oauth2Proxy.existingSecret.name is required" .Values.oauth2Proxy.existingSecret.name }}
{{- if lt (len .Values.dashboard.administratorUsers) 1 }}
{{- fail "dashboard.administratorUsers must contain at least one Entra identity" }}
{{- end }}
{{- end }}
