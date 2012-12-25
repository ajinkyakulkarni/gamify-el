;;; gamify.el --- Gamify your GTD!  -*- coding: mule-utf-8 -*-

;; Copyright (C) 2012 Kajetan Rzepecki

;; Author: Kajetan Rzepecki

;; Keywords: gamification gtd

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Usage:

;; (require 'gamify)
;; (gamify-start)


;; There are quite a few variables to tweak:
;; - `gamify-update-interval' - number of seconds between mode-line updates.
;; - `gamify-format' - format string used in the mode-line:
;;    %T - total exp point you own,
;;    %XP - "level-bar" percentage,
;;    %xp - focus stat percentage,
;;    %Lc - current level name,
;;    %Ln - next level name.
;; - `gamify-default-exp' - default base exp value used by `gamify-some-exp'.
;; - `gamify-default-exp-delta' - default exp delta used by `gamify-some-exp'.
;; - `gamify-stats-file' - file where Gamify should save your stats.
;; - `gamify-very-rusty-time' - time in seconds, when your skills are considered "very rusty".
;; - `gamify-rusty-time' - time in seconds, when your skills are considered "rusty".
;; - `gamify-stat-level' - an alist of exp values and level names for your stats.
;;                         Defaults to Dwarf Fortress-esque skill set.
;; - `gamify-org-p' - tell Gamify wether to gamify your Org-Mode tasks, or not.

;;; TODO:

;; Skill-of-focus, achievements and quest items!

;;; Code:

(require 'cl)
(require 'misc-utils)

(defvar gamify-last-stats-modification-time 0)
(defvar gamify-timer nil)
(defvar gamify-mode-line-string "")
(defvar gamify-formatters ())
(defvar gamify-stats-alist ())

(defgroup gamify nil
  "Display your Gamify stats in the mode-line."
  :group 'gamify)

(defcustom gamify-update-interval 10
  "Number of seconds between stats update."
  :type 'number
  :group 'gamify)

(defcustom gamify-format "%XP"
  "Format string:
%T - total exp point you own,
%XP - \"level-bar\" percentage,
%xp - focus stats percentage,
%Lc - current level name,
%Ln - next level name."
  :type 'string
  :group 'gamify)

(defcustom gamify-exp-property "gamify_exp"
  "Property used by Org-Mode tasks to assign experience points."
  :type 'string
  :group 'gamify)

(defcustom gamify-default-exp 10
  "Default exp level to assign to a task."
  :type 'number
  :group 'gamify)

(defcustom gamify-default-exp-delta 5
  "Tiny exp delta, just for kicks."
  :type 'number
  :group 'gamify)

(defcustom gamify-stats-file "~/.emacs.d/gamify-stats"
  "Save file for the gamify stats."
  :type 'string
  :group 'gamify)

(defcustom gamify-very-rusty-time (* 3 30 24 60 60)
  "Time in seconds when stats get very rusty."
  :type 'number
  :group 'gamify)

(defcustom gamify-rusty-time (* 14 24 60 60)
  "Time in seconds when stats get rusty."
  :type 'number
  :group 'gamify)

(defcustom gamify-focus-stats nil
  "Stats Gamify should focus on."
  :type 'list
  :group 'gamify)

(defcustom gamify-stat-levels
  '((0 . "Dabbling")
    (500 . "Novice")
    (1100 . "Adequate")
    (1800 . "Competent")
    (2600 . "Skilled")
    (3500 . "Proficient")
    (4500 . "Talented")
    (5600 . "Adept")
    (6800 . "Expert")
    (8100 . "Professional")
    (9500 . "Accomplished")
    (11000 . "Great")
    (12600 . "Master")
    (14300 . "HighMaster")
    (16100 . "GrandMaster")
    (18000 . "Legendary")
    (333333333333333 . "CHEATER"))
  "An alist of Gamify levels and their exp values."
  :group 'gamify)

(defcustom gamify-org-p nil
 "Gamify Org-Mode tasks?"
 :type 'boolean
 :group 'gamify)

(defun gamify-stats ()
  "Show pretty, pretty stats."
  (interactive)
  (setq gamify-last-pretty-stats-msg ())  ;; We need fresh stats, yo.
  (message (gamify-get-pretty-stats))
  (setq gamify-last-pretty-stats-msg ())) ;; Regenerate them again.

(defvar gamify-last-pretty-stats-time 0)               ;; Used for cacheing.
(defvar gamify-last-pretty-stats-msg ())               ;; ditto
(defvar gamify-pretty-stats-update-interval (* 10 60)) ;; 10 minutes

(defun gamify-get-total-exp (name &optional visited)
  (when (assoc name gamify-stats-alist)
    (let* ((skill (assoc name gamify-stats-alist))
           (exp (cadr skill))
           (dependancies (nth 3 skill))
           (deps-names (map 'list
                            (lambda (dep)
                              (if (listp dep)
                                  (car dep)
                                  dep))
                            dependancies))
           (exclude (cons name (append deps-names visited)))
           (total-exp exp))
      (dolist (dependancy dependancies)
        (let ((dep-name (if (listp dependancy)
                            (car dependancy)
                            dependancy))
              (dep-factor (if (listp dependancy)
                              (cadr dependancy)
                              1.0)))
          (unless (member dep-name visited)
            (setq total-exp
                  (+ total-exp
                     (round (* dep-factor
                               (or (gamify-get-total-exp dep-name exclude) 0))))))))
      total-exp)))

(defun gamify-rusty-p (stat-name)
  (let* ((curr-time (float-time (current-time)))
         (stat (assoc stat-name gamify-stats-alist))
         (mod-time (nth 2 stat))
         (time-delta (- curr-time mod-time)))
    (cond ((> time-delta gamify-very-rusty-time) 'very-rusty)
          ((> time-delta gamify-rusty-time)       'rusty)
          (t nil))))

(defun gamify-get-pretty-stats (&optional skip-levels)
  (let ((current-time (float-time (current-time))))
    (when (or (not gamify-last-pretty-stats-msg)
              (> (- current-time gamify-last-pretty-stats-time)
                 gamify-pretty-stats-update-interval)
              (> gamify-last-stats-modification-time
                 gamify-last-pretty-stats-time))
      (setq gamify-last-pretty-stats-time current-time)
      (setq gamify-last-pretty-stats-msg
            (concat "Your Gamify stats:\n"
               (apply #'concat
                 (map 'list
                      (lambda (e)
                        (let* ((name (car e))
                               (mod-time (nth 2 e))
                               (total-exp (gamify-get-total-exp name (list name)))
                               (level (gamify-get-level total-exp))
                               (time-delta (- current-time mod-time))
                               (rustiness (gamify-rusty-p name))
                               (rustiness-str (cond ((equal rustiness 'very-rusty)
                                                     " (Very rusty)")
                                                    ((equal rustiness 'rusty)
                                                     " (Rusty)")
                                                    (t ""))))
                          (unless (member (caar level) skip-levels)
                            (format "%s at %s%s: %d/%d\n"
                                    (caar level)
                                    (gamify-stat-name name)
                                    rustiness-str
                                    total-exp
                                    (cddr level)))))
                      gamify-stats-alist))))))
  gamify-last-pretty-stats-msg)

(defvar gamify-dot-show-exp t)
(defvar gamify-dot-name-threshold 12)
(defvar gamify-dot-min-font-size 12.0)
(defvar gamify-dot-max-font-size 24.0)
(defvar gamify-dot-min-node-size 1.0)
(defvar gamify-dot-max-node-size 3.0)
(defvar gamify-dot-border-size 3)
(defvar gamify-dot-node-shape "circle")
(defvar gamify-dot-node-fill-color "#ffffff")
(defvar gamify-dot-edge-color "#000000")
(defvar gamify-dot-default-node-color "#e0e0e0")
(defvar gamify-dot-default-font-color "#d8d8d8")
(defvar gamify-dot-font-color "#000000")
(defvar gamify-dot-rusty-font-color "#d8d8d8")
(defvar gamify-dot-very-rusty-font-color "#989898")
(defvar gamify-dot-background-color "#ffffff")
(defvar gamify-dot-level-colors
  '(("Dabbling")
    ("Novice")
    ("Adequate")
    ("Competent")
    ("Skilled")
    ("Proficient")
    ("Talented")
    ("Adept")
    ("Expert")
    ("Professional")
    ("Accomplished")
    ("Great")
    ("Master")
    ("HighMaster")
    ("GrandMaster")
    ("Legendary")
    ("CHEATER" . "#FF0000")))

(defun gamify-stats-to-dot (filename &optional skip-levels)
  "Exports your Gamify stats to .dot format."
  (with-temp-buffer
    (insert "digraph YourStats {\n")
    (insert (format "bgcolor=\"%s\";\n"
                    gamify-dot-background-color))
    (insert (format (concat "node [penwidth=2, shape=%s, width=%.2f, color=\"%s\","
                            " fontcolor=\"%s\", fixedsize=true, fontsize=\"%s\""
                            " style=filled, fillcolor=\"%s\"];")
                    gamify-dot-node-shape
                    gamify-dot-min-node-size
                    gamify-dot-default-node-color
                    gamify-dot-default-font-color
                    gamify-dot-min-font-size
                    gamify-dot-node-fill-color))
    (insert (format "edge [penwidth=2, color=\"%s\", fontcolor=\"%s\"];\n"
                    gamify-dot-edge-color
                    gamify-dot-font-color))

    (let ((max-exp (apply #'max (map 'list
                                     (lambda (e)
                                       (gamify-get-total-exp (car e)))
                                     gamify-stats-alist))))
      (dolist (stat gamify-stats-alist)
        (let* ((name (car stat))
               (printed-name (if (>= (length name) gamify-dot-name-threshold)
                                 (gamify-stat-name name"\\n")
                                 name))
               (exp (nth 1 stat))
               (dependancies (nth 3 stat))
               (total-exp (gamify-get-total-exp name))
               (level (gamify-get-level total-exp))
               (size-factor (sqrt (/ (float total-exp) max-exp)))
               (node-size (+ gamify-dot-min-node-size
                             (* size-factor
                                (- gamify-dot-max-node-size
                                   gamify-dot-min-node-size))))
               (label (if gamify-dot-show-exp
                          (format "%s\\n%d (%d%%)"
                                  printed-name
                                  total-exp
                                  (gamify-get-level-percentage total-exp))
                          (format "%s at\\n%s"
                                  (gamify-stat-name (caar level))
                                  printed-name)))
               (node-color (cdr (assoc (caar (gamify-get-level total-exp))
                                       gamify-dot-level-colors)))
               (font-color (or (case (gamify-rusty-p name)
                                 (very-rusty gamify-dot-very-rusty-font-color)
                                 (rusty gamify-dot-rusty-font-color))
                               gamify-dot-font-color))
               (font-size (+ gamify-dot-min-font-size
                             (* (- gamify-dot-max-font-size
                                   gamify-dot-min-font-size)
                                size-factor))))
          (unless (member (caar level) skip-levels)
            (insert (format (concat "\"%s\" [penwidth=%d, shape=%s, width=%.2f,"
                                    " fixedsize=true, label=\"%s\", color=\"%s\","
                                    " fontcolor=\"%s\", style=filled, fillcolor=\"%s\""
                                    " fontsize=\"%.2f\"];\n")
                            name
                            gamify-dot-border-size
                            gamify-dot-node-shape
                            node-size
                            label
                            node-color
                            font-color
                            gamify-dot-node-fill-color
                            font-size))
            (dolist (dependancy dependancies)
              (insert (if (listp dependancy)
                          (format "\"%s\" -> \"%s\" [label=\"%.1f\"];\n"
                                  (car dependancy)
                                  name
                                  (cadr dependancy))
                          (format "\"%s\" -> \"%s\";\n" dependancy name))))))))
    (insert "}\n")
    (write-file filename)))

(defun gamify-stats-to-png (filename &optional skip-levels)
  "Exports your stats directly to a .png file using the `dot' layout."
  (let ((tmp-file (concat "/tmp/" (md5 filename) ".dot")))
    (gamify-stats-to-dot tmp-file skip-levels)
    (shell-command-to-string
      (concat "ccomps -x " tmp-file
              " | dot | gvpack -array3 | neato -Tpng -n2 -o "
              filename))))

(defun gamify-stat-name (name &optional separator)
  (mapconcat 'identity
             (split-string-on-case name)
             (or separator " ")))

(defun gamify-assign-some-exp (&optional low delta)
  (number-to-string (gamify-some-exp low delta)))

(defun gamify-some-exp (&optional low delta)
  (+ (or low gamify-default-exp)
     (% (random t) (1+ (or delta gamify-default-exp-delta)))))

(defun gamify-focus-on (stats)
  (setq gamify-focus-stats stats))

(defun gamify-save-stats ()
  "Saves the stats to `gamify-stats-file'."
  (interactive)
  (with-temp-buffer
    (insert ";; -*- emacs-lisp -*-\n")
    (insert ";; This file was generated by Gamify.\n")
    (insert ";; DON'T CHEAT, that's gay.\n\n")
    (insert "(setq gamify-stats-alist '(\n")
    (dolist (stat gamify-stats-alist)
      (insert (prin1-to-string stat))
      (insert "\n"))
    (insert "))")
    (write-file gamify-stats-file)))

(defun gamify-show-stats ()
  (let ((total-exp (apply #'+ (map 'list #'cadr gamify-stats-alist))))
    (format-expand gamify-formatters gamify-format (list total-exp gamify-stats-alist))))

(defun gamify-get-level (exp)
  (let ((current nil)
        (next nil))
    (loop for (e . l) in gamify-stat-levels
          if (and (not next)
                  (< exp e))
          do (setq next (cons l e))
          if (>= exp e)
          do (setq current (cons l e)))
    (cons current next)))

(defun gamify-get-level-percentage (curr-exp)
  (let* ((level (gamify-get-level curr-exp))
         (current (car level))
         (next (cdr level))
         (delta (- (cdr next) (cdr current)))
         (exp (- curr-exp (cdr current))))
    (/ (* 100.0 exp) delta)))

(defun gamify-org-add-exp (arg)
  "A hook used to gamify Org-Mode tasks. Usage:
- Tag your tasks with somethis meaningful, e. g. \"coding\".
- Add \"gamify_exp\" property containing the experience value of a task.
- ???
- PROFI!"

  (require 'org)
  (require 'org-habit)
  (when (and (equal (plist-get arg :type) 'todo-state-change)
             (equal (plist-get arg :to) "DONE"))
    (let* ((curr-time (float-time (current-time)))
           (pos (plist-get arg :position))
           (stats (org-get-tags-at pos))
           (curr-date (calendar-absolute-from-gregorian (calendar-current-date)))
           (date curr-date)
           (gamify-exp (assoc gamify-exp-property
                              (org-entry-properties pos)))
           (exp-str (if gamify-exp
                        (cdr gamify-exp)
                        "0"))
           (exp-val (read exp-str))
           (exp (cond ((numberp exp-val) exp-val)
                      ((listp exp-val)   (apply #'gamify-some-exp exp-val))
                      (t                 0))))

      (goto-char pos)
      (save-excursion
        (save-restriction
          (org-narrow-to-subtree)
          (when (or (re-search-forward org-deadline-time-regexp nil t)
                     (re-search-forward org-scheduled-time-regexp nil t))
            ;; NOTE Won't work for some reason.
            ;; (setq date (org-time-string-to-absolute
            ;;            (match-string 1) curr-date 'past t))
            (setq date (- (org-time-string-to-absolute (match-string 1))
                          (org-habit-duration-to-days (or (org-get-repeat) "0d")))))))

      (unless (equal exp 0)
        (let* ((notify-text '())
               (diff (- date curr-date))
               ;; Penalties should be moderate.
               (penalty (if (< diff (- (/ exp 2)))
                            (- (/ exp 2))
                            diff))
               (penalty-str (cond ((< penalty 0) (format " (%d overdue penalty)" penalty))
                                  ((> penalty 0) (format " (%d bonus exp)" penalty))
                                  (t "")))
               (levelup-str ""))

          (dolist (stat stats)
            (let ((curr-exp (assoc stat gamify-stats-alist)))
              (when curr-exp
                (let* ((curr-total (cadr curr-exp))
                       (total-exp (+ curr-total exp penalty))
                       (level (gamify-get-level (gamify-get-total-exp stat)))
                       (next-level-exp (cddr level))
                       (next-level (cadr level)))
                (setq levelup-str
                      (if (>= total-exp next-level-exp)
                          (format " You are now %s!\n" next-level)
                         "\n"))
                (setf (cadr curr-exp) total-exp)
                (setf (caddr curr-exp) curr-time)
                (setq gamify-last-stats-modification-time curr-time)))

              (unless curr-exp
                (setq levelup-str "\n")
                (add-to-list 'gamify-stats-alist
                  (list stat
                        (+ exp penalty)
                        curr-time
                        (when (y-or-n-p "This is a new skill. Care to add its dependancies? ")
                          ;; FIXME post-command-hook error
                          (delq ""
                                (split-string
                                  (read-string "Enter a space-separated list of stats: "))))))))
            (add-to-list 'notify-text
                         (format "You earned %d XP in %s%s!%s"
                                 (+ exp penalty)
                                 stat
                                 penalty-str
                                 levelup-str)))

          (notify-send "QUEST COMPLETED"
                       (apply #'concat notify-text)
                       (concat my-stuff-dir "xp.png")))))))

(defun gamify-org-agenda-tasks ()
  "Set focus stats from Org Agenda buffer."
  (interactive)
  (when (string= (buffer-name) org-agenda-buffer-name)
    (let* ((marker (get-text-property (point) 'org-hd-marker))
           (props (org-entry-properties marker))
           (exp (assoc gamify-exp-property props))
           (tags (assoc "ALLTAGS" props))
           (tags-list (when tags
                        (delq "" (split-string (cdr tags) ":")))))
        (gamify-focus-on tags-list))))

(defun gamify-start ()
  "Starts the gamification!"
  (interactive)
  (add-to-list 'global-mode-string 'gamify-mode-line-string t)
  (and gamify-timer (cancel-timer gamify-timer))

  (when (file-exists-p gamify-stats-file)
    (load-file gamify-stats-file))

  (add-hook 'auto-save-hook 'gamify-save-stats)
  (add-hook 'kill-emacs-hook 'gamify-save-stats)

  (when gamify-org-p
    (add-hook 'org-trigger-hook 'gamify-org-add-exp))

  (setq gamify-mode-line-string (gamify-show-stats))
  (setq gamify-timer (run-at-time gamify-update-interval
                                  gamify-update-interval
                                  (lambda ()
                                    (setq gamify-mode-line-string (gamify-show-stats))
                                    (force-mode-line-update)
                                    (sit-for 0)))))

(defun gamify-stop ()
  "Stops the gamification."
  (interactive)
  (setq gamify-mode-line-string "")
  (setq global-mode-string (delq 'gamify-mode-line-string
                                  global-mode-string))

  (remove-hook 'auto-save-hook 'gamify-save-stats)
  (remove-hook 'kill-emacs-hook 'gamify-save-stats)
  (when gamify-org-p
    (remove-hook 'auto-save-hook 'gamify-org-add-exp))

  (setq gamify-timer (and gamify-timer
                          (cancel-timer gamify-timer)))
  (gamify-save-stats))

(setq gamify-formatters
  '(("T" . (lambda (stats)
              (format "%d" (car stats))))
    ("XP" . (lambda (stats)
              (format "%.1f"
                      (gamify-get-level-percentage (car stats)))))
    ("xp" . (lambda (stats)
              (format "%.1f"
                      (gamify-get-level-percentage
                        (apply #'min
                               (or (delq nil
                                   (map 'list
                                        (lambda (stat)
                                          (gamify-get-total-exp stat))
                                        gamify-focus-stats))
                                   '(0)))))))
    ("Lc" . (lambda (stats)
              (format "%s" (caar (gamify-get-level (car stats))))))
    ("Ln" . (lambda (stats)
              (format "%s" (cadr (gamify-get-level (car stats)))))))

    ;; TODO Top skills
    ;; etc
)

(provide 'gamify)