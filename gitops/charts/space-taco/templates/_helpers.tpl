{{/*
Expand the name of the chart.
*/}}
{{- define "space-taco.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "space-taco.fullname" -}}
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
Create chart label.
*/}}
{{- define "space-taco.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "space-taco.labels" -}}
helm.sh/chart: {{ include "space-taco.chart" . }}
{{ include "space-taco.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "space-taco.selectorLabels" -}}
app.kubernetes.io/name: {{ include "space-taco.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "space-taco.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "space-taco.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Deployment name for a given blue/green slot. Pass dict "root" $ "slotName" "blue"|"green"|"".
Empty slotName renders the plain (non-blue/green) Deployment name.
*/}}
{{- define "space-taco.deploymentName" -}}
{{- $root := .root }}
{{- $slotName := .slotName }}
{{- if $slotName }}
{{- printf "%s-%s" (include "space-taco.fullname" $root) $slotName }}
{{- else }}
{{- include "space-taco.fullname" $root }}
{{- end }}
{{- end }}

{{/*
Renders one Deployment manifest. Pass dict "root" $ "slotName" "blue"|"green"|"" "slotConfig" (slot values or empty dict).
Used twice (blue + green) when .Values.blueGreen.enabled, otherwise once with slotName "".
When slotName is set, pods get an extra "version: <slotName>" label so the
single stable Service (selector has no version) matches both slots, while
Istio's DestinationRule can still tell them apart by that label.
*/}}
{{- define "space-taco.deployment" -}}
{{- $root := .root }}
{{- $slotName := .slotName }}
{{- $slotConfig := .slotConfig }}
{{- $replicaCount := $root.Values.replicaCount }}
{{- $imageTag := $root.Values.image.tag }}
{{- if $slotName }}
{{- if $slotConfig.replicaCount }}{{- $replicaCount = $slotConfig.replicaCount }}{{- end }}
{{- if $slotConfig.image }}{{- if $slotConfig.image.tag }}{{- $imageTag = $slotConfig.image.tag }}{{- end }}{{- end }}
{{- end }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "space-taco.deploymentName" . }}
  labels:
    {{- include "space-taco.labels" $root | nindent 4 }}
    {{- if $slotName }}
    version: {{ $slotName }}
    {{- end }}
spec:
  {{- if not $root.Values.autoscaling.enabled }}
  replicas: {{ $replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "space-taco.selectorLabels" $root | nindent 6 }}
      {{- if $slotName }}
      version: {{ $slotName }}
      {{- end }}
  template:
    metadata:
      annotations:
        {{- with $root.Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      labels:
        {{- include "space-taco.labels" $root | nindent 8 }}
        {{- if $slotName }}
        version: {{ $slotName }}
        {{- end }}
        {{- with $root.Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "space-taco.serviceAccountName" $root }}
      securityContext:
        {{- toYaml $root.Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ $root.Chart.Name }}
          securityContext:
            {{- toYaml $root.Values.securityContext | nindent 12 }}
          {{- $repo := $root.Values.image.repository }}
          {{- $tag  := $imageTag | default $root.Chart.AppVersion }}
          {{- $image := ternary (printf "%s/%s:%s" $root.Values.image.registry $repo $tag) (printf "%s:%s" $repo $tag) (ne $root.Values.image.registry "") }}
          image: {{ $image | quote }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ $root.Values.env.PORT | default 8080 }}
              protocol: TCP
          env:
            - name: PORT
              value: {{ $root.Values.env.PORT | quote }}
            {{- if $root.Values.env.REDIS_URL }}
            - name: REDIS_URL
              value: {{ $root.Values.env.REDIS_URL | quote }}
            {{- end }}
          livenessProbe:
            {{- toYaml $root.Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml $root.Values.readinessProbe | nindent 12 }}
          resources:
            {{- toYaml $root.Values.resources | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
