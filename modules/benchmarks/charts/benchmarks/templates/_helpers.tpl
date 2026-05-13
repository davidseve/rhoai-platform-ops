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
