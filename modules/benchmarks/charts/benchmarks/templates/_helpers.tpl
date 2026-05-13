{{- define "benchmarks.fullname" -}}
{{ .Values.global.name }}
{{- end }}

{{- define "benchmarks.namespace" -}}
{{ .Values.global.namespace }}
{{- end }}

{{- define "benchmarks.labels" -}}
app.kubernetes.io/name: {{ include "benchmarks.fullname" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rhoai-platform-ops
{{- end }}

{{- define "benchmarks.selectorLabels" -}}
app.kubernetes.io/name: {{ include "benchmarks.fullname" . }}
{{- end }}

{{/*
Build --backend-kwargs JSON. SSL verification handled via cluster CA bundle
mount + SSL_CERT_FILE env var; only api_key needed here when auth is configured.
*/}}
{{- define "benchmarks.backendKwargs" -}}
{{- if or .Values.benchmark.authToken .Values.benchmark.authSecret -}}
{"api_key": "$(AUTH_TOKEN)"}
{{- else -}}
{}
{{- end -}}
{{- end }}
