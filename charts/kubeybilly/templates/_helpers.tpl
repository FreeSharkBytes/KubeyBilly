{{/*
Chart name.
*/}}
{{- define "kubeybilly.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name: release name, with the chart name appended only
when the release is not already named after the chart.
*/}}
{{- define "kubeybilly.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "kubeybilly.labels" -}}
app.kubernetes.io/name: {{ include "kubeybilly.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Selector labels (stable subset, never changed after first install).
*/}}
{{- define "kubeybilly.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubeybilly.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
