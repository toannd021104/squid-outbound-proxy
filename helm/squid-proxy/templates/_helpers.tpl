{{/*
Expand the name of the chart.
*/}}
{{- define "squid-proxy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "squid-proxy.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "squid-proxy.labels" -}}
helm.sh/chart: {{ include "squid-proxy.name" . }}-{{ .Chart.Version }}
{{ include "squid-proxy.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "squid-proxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "squid-proxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Proxy URL — dùng cho HTTP_PROXY injection
*/}}
{{- define "squid-proxy.proxyUrl" -}}
{{- if .Values.proxyInjector.proxyUrl }}
{{- .Values.proxyInjector.proxyUrl }}
{{- else }}
{{- printf "http://%s.%s.svc.cluster.local:%d" (include "squid-proxy.fullname" .) .Values.namespace (.Values.squid.port | int) }}
{{- end }}
{{- end }}
