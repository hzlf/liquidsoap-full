(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2009 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

(** This modules contains fonctions related to frames which are small blocks
  * containing data (audio, video, etc.). They can contain multiple kind of data
  * each kind being located in a track. *)

(** {2 Types} *)

(** Frame. *)
type t

(** PCM data. *)
type float_pcm = float array

(** For now, we only specify the sampling frequency for PCM data. *)
type float_pcm_t = float

(** Contents of tracks. *)
type track_t =
  | Float_pcm_t of float_pcm_t (** PCM data *)
  | Midi_t (** MIDI data *)
  | RGB_t (** YUV video data *)

(** Tracks. *)
type track =
  | Float_pcm of (float_pcm_t * float_pcm) (** PCM data *)
  | Midi of (int * Midi.event) list ref (** MIDI data *)
  | RGB of RGB.t array (** YUV data as an array of frames *)

(** {2 Basic manipulation} *)

(** [create type freq length] creates a new frame whose tracks are of type
  * [type], where [freq] is the number of ticks in a second and [length] is its
  * length in ticks. *)
val create : track_t array -> freq:int -> length:int -> t

(** Create a frame with the default parameters. *)
val make : unit -> t

(** Get the kind of contents of the tracks of a frame. *)
val kind   : t -> track_t array

(** Get the tracks contained in a frame. *)
val get_tracks : t -> track array

(** Add a track to a frame. *)
val add_track : t -> track -> unit

(** Duration in seconds. *)
val duration : t -> float

(** {2 Breaks} *)

(** Breaks are track limits. All the durations are given in ticks. *)

(** Length of a frame in ticks. *)
val size       : t -> int

(** Get the current position in a frame. *)
val position   : t -> int

(** Breaks of a frame. *)
val breaks     : t -> int list

(** Add a break to a frame. *)
val add_break  : t -> int -> unit

(** Set all the breaks of a frame. *)
val set_breaks : t -> int list -> unit

(** Is a frame partially filled? *)
val is_partial : t -> bool

(** Reset breaks and metadata. *)
val clear : t -> unit

(** Reset breaks and metadata, but leaves the last metadata at position -1. *)
val advance : t -> unit

(** {2 Metadatas handling} *)

(** Raised when there is no metadata in the frame. *)
exception No_metadata

(** Metadata is represented by a table associating strings to strings,
  * located at some instant (and not for some interval). *)
type metadata = (string,string) Hashtbl.t

(** Remove the metadata at a given time (in ticks). *)
val free_metadata    : t -> int -> unit

(** Set the metdata at a given time (in ticks). *)
val set_metadata     : t -> int -> metadata -> unit

(** Get the metadata at a given time (in ticks). *)
val get_metadata     : t -> int -> metadata option

(** Remove all metadata from a frame. *)
val free_all_metadata : t -> unit

(** Get all the metadata of a frame (and the time they are set). *)
val get_all_metadata : t -> (int*metadata) list

(** Get the stored past metadata of a frame (rather, stream). *)
val get_past_metadata : t -> metadata option

(** Set all the metadata of a frame (and the time they are set). *)
val set_all_metadata : t -> (int*metadata) list -> unit

(** {2 Chunks} *)

exception No_chunk

(** [get_chunk buf inbuf] fills [buf] with data from [inbuf] starting at current
  * position for both buffers. *)
val get_chunk : t -> t -> unit

(** Fill a frame from a out_chan using the Marshal module. *)
val fill_from_marshal : in_channel -> t -> unit

(** {2 Other} *)

(** [blit src src_pos dst dst_pos len]: copy [len] data from [src], starting
  * at [src_pos] to [dst], starting at [dst_pos]. *)
val blit : t -> int -> t -> int -> int -> unit