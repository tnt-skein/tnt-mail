@extends('mail.layout')
@section('title', 'Вам ответили')
@section('content')
<p>{{ name }}, в теме «{{ thread }}» новый ответ:</p>
<blockquote>{{ reply }}</blockquote>
<p><a href="{{ link }}">{{ link }}</a></p>
@endsection
